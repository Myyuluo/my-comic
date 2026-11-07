/// 拖入 Local source root 的过渡路径：先把文件夹 / CBZ **复制**进
/// `localcomic`，再登记；原始文件保持不动（ADR 0013 / storage-layout spec）。
///
/// 未来的「源」里的 Local source 入口会取代拖入；本条是当前版本的过渡行为。
/// CBZ 的章节扫描/登记属于 ticket 07，本文件只负责把包复制到
/// `localcomic/{manga}/{chapter}.cbz` 的位置。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';

export 'package:fushi_engine/media/manga/local_source/local_source_library.dart'
    show LocalSourceImportReport;

/// 拖入内容无法作为 Local source 载体时抛出。
class LocalSourceDropException implements Exception {
  const LocalSourceDropException(this.message);

  final String message;

  @override
  String toString() => 'LocalSourceDropException: $message';
}

/// 一次拖入的结果。
class LocalSourceDropResult {
  const LocalSourceDropResult({
    this.mangaDirectory,
    this.copiedPath,
    required this.registered,
    this.report,
  });

  /// 复制后（或本来就在 root 里）的作品目录；CBZ 尚未登记时为 null。
  final Directory? mangaDirectory;

  /// 实际复制出的文件 / 目录路径；目录拖入且无需复制时为空。
  final String? copiedPath;

  /// 本次拖入后是否在 Library 里找到了对应条目。
  final bool registered;

  final LocalSourceImportReport? report;
}

/// 拖入文件夹或 CBZ 的落地入口。
abstract final class LocalSourceDrop {
  /// 把 [sourcePath] 复制进 [root] 并登记。
  ///
  /// - 文件夹：复制成 `root/{文件夹名}`（同名 ` (2)` 后缀），随后扫描登记；
  /// - `.cbz`：复制成 `root/{文件名}/{文件名}.cbz`，原文件保留；章节登记由
  ///   ticket 07 接管（此处返回 `registered: false`）；
  /// - 来源本身已在 [root] 内：不复制，直接登记。
  static Future<LocalSourceDropResult> importDroppedPath({
    required FushiDatabase db,
    required Directory root,
    required String sourcePath,
  }) async {
    final FileSystemEntityType type = FileSystemEntity.typeSync(
      sourcePath,
      followLinks: false,
    );
    final LocalSourceLibrary library = LocalSourceLibrary(db: db, root: root);
    if (type == FileSystemEntityType.directory) {
      final Directory source = Directory(sourcePath);
      final String rootCanon = p.canonicalize(root.path);
      final String sourceCanon = p.canonicalize(source.path);
      if (p.equals(rootCanon, sourceCanon) ||
          p.isWithin(rootCanon, sourceCanon)) {
        final LocalSourceImportReport report = await library.importFromRoot();
        return _registeredResult(
          db: db,
          directory: source,
          copiedPath: null,
          report: report,
        );
      }
      final Directory destination = _uniqueDirectory(
        root,
        p.basename(source.path),
      );
      await _copyDirectory(source, destination);
      final LocalSourceImportReport report = await library.importFromRoot();
      return _registeredResult(
        db: db,
        directory: destination,
        copiedPath: destination.path,
        report: report,
      );
    }
    if (type == FileSystemEntityType.file) {
      final File source = File(sourcePath);
      final String extension = p.extension(source.path).toLowerCase();
      if (extension != '.cbz') {
        throw LocalSourceDropException(
          'Local source only accepts folders or .cbz files: $sourcePath',
        );
      }
      final String baseName = p.basenameWithoutExtension(source.path);
      final Directory destination = _uniqueDirectory(root, baseName);
      await destination.create(recursive: true);
      final File copied = await source.copy(
        p.join(destination.path, p.basename(source.path)),
      );
      return LocalSourceDropResult(copiedPath: copied.path, registered: false);
    }
    throw LocalSourceDropException(
      'Local source only accepts folders or .cbz files: $sourcePath',
    );
  }

  static Future<LocalSourceDropResult> _registeredResult({
    required FushiDatabase db,
    required Directory directory,
    required String? copiedPath,
    required LocalSourceImportReport report,
  }) async {
    final String bookKey = localSourceBookKeyFor(directory.path);
    final EpubBookRow? row = await db.getEpubBook(bookKey);
    return LocalSourceDropResult(
      mangaDirectory: row == null ? null : directory,
      copiedPath: copiedPath,
      registered: row != null,
      report: report,
    );
  }

  /// `root/base`；同名时依次 `root/base (2)`、`root/base (3)`……绝不覆盖。
  static Directory _uniqueDirectory(Directory root, String baseName) {
    Directory candidate = Directory(p.join(root.path, baseName));
    for (int i = 2; candidate.existsSync(); i++) {
      candidate = Directory(p.join(root.path, '$baseName ($i)'));
    }
    return candidate;
  }

  static Future<void> _copyDirectory(
    Directory source,
    Directory destination,
  ) async {
    await destination.create(recursive: true);
    for (final FileSystemEntity entity in source.listSync(followLinks: false)) {
      if (entity is File) {
        await entity.copy(p.join(destination.path, p.basename(entity.path)));
      } else if (entity is Directory) {
        await _copyDirectory(
          entity,
          Directory(p.join(destination.path, p.basename(entity.path))),
        );
      }
      // Link / socket：不支持也不跟随，避免复制出环。
    }
  }
}
