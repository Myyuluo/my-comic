import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha1;
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// 书架书籍（含下载到本地的漫画章节容器）在 Content root 下的存储根。
///
/// 原住在 `epub/epub_storage.dart`（EPUB 阅读域）。漫画下载库把每一卷下载内容
/// 按 `epub_books` 行的 `extract_dir` 落到 `<Content root>/fushi_books/<key>/`，
/// 删除书架条目 / 清空下载也都经本类删目录；目录名与测试注入点已冻结。这里只保留
/// 漫画域真正使用的存储 API，不包含 EPUB 导入器的其余职责。
///
/// Layout: `<appDocDir>/fushi_books/<bookKey>/`
///   - 下载的漫画页、`pages.json`、mokuro sidecar 等
///
/// NOTE: pre-v16 books were stored under `<appDocDir>/fushi_books/<int id>/`.
/// Those directories are NOT renamed on migration — the truth is the
/// `epub_books.extract_dir` column. Use [bookDirectory]/[bookPath] only when
/// importing a NEW book; to locate an EXISTING book read its `extractDir`
/// column and operate on that absolute path (e.g. [deleteBookDir]).
class EpubStorage {
  static String? _cachedBaseDir;

  /// Test-only override for the base directory, used by suites that exercise
  /// the real importers without a Flutter binding / path_provider plugin.
  /// Production never sets this — it stays null and resolution falls
  /// through to the host's Content root (`AppPaths.contentRootDirectory`).
  @visibleForTesting
  static set debugBaseDirectoryOverride(String? path) {
    _cachedBaseDir = path == null ? null : p.join(path, 'fushi_books');
  }

  /// 当前测试注入的书根（null = 生产解析）。供需要在同一临时根下派生兄弟目录
  /// （如 Download library）的测试缝使用。
  static String? get debugBaseDirectoryOverridePath => _cachedBaseDir;

  /// Base directory for all extracted books.
  static Future<String> baseDirectory() async {
    if (_cachedBaseDir != null) return _cachedBaseDir!;
    final Directory appDir = await enginePaths.documentsRootDirectory();
    _cachedBaseDir = p.join(appDir.path, 'fushi_books');
    return _cachedBaseDir!;
  }

  /// Directory for a NEW book (keyed by its bookKey). Creates it if missing.
  static Future<String> bookDirectory(String bookKey) async {
    final String base = await baseDirectory();
    final String dir = p.join(base, bookKey);
    final Directory d = Directory(dir);
    if (!d.existsSync()) {
      d.createSync(recursive: true);
    }
    return dir;
  }

  /// Path for a NEW book — does NOT create the directory.
  static Future<String> bookPath(String bookKey) async {
    final String base = await baseDirectory();
    return p.join(base, bookKey);
  }

  /// Delete an extracted directory by its absolute path (the stored
  /// `extract_dir` column). Use this to remove an existing book whose on-disk
  /// folder name may still be a legacy int id.
  ///
  /// Also drops the book's derived illustration-index cache, which lives under
  /// the support root keyed by this path (BUG-3433) — first, so a locked
  /// extract dir (Windows errno 32) cannot leave it orphaned.
  static Future<void> deleteBookDir(String extractDir) async {
    if (extractDir.isEmpty) return;
    await deleteEpubImageIndexCache(extractDir);
    final Directory dir = Directory(extractDir);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  /// Check whether an extracted directory at [extractDir] exists and has
  /// content.
  static Future<bool> bookDirExists(String extractDir) async {
    if (extractDir.isEmpty) return false;
    final Directory dir = Directory(extractDir);
    return dir.existsSync() && dir.listSync().isNotEmpty;
  }
}

/// support 根下的插图表缓存目录名（历史遗留，删书时仍需清理）。
const String kEpubImageIndexCacheDirName = 'epub_image_index';

/// 删掉解压目录 [extractDir] 对应的插图表缓存（删书时调用，见
/// [EpubStorage.deleteBookDir]）。缓存按解压目录路径命名，不删的话这份文件成孤儿。
/// 根 isolate 调用；失败经 [engineLog] 记录、不向上抛——它是派生物，删书本身不能
/// 因它失败。
Future<void> deleteEpubImageIndexCache(String extractDir) async {
  if (extractDir.isEmpty || enginePaths is UninstalledEnginePaths) return;
  try {
    final Directory root = await enginePaths.supportRootDirectory();
    final String key = sha1
        .convert(utf8.encode(p.canonicalize(extractDir)))
        .toString();
    final File file = File(
      p.join(root.path, kEpubImageIndexCacheDirName, '$key.json'),
    );
    if (file.existsSync()) file.deleteSync();
  } on Object catch (error, stack) {
    engineLog.log('deleteEpubImageIndexCache', error, stack);
  }
}
