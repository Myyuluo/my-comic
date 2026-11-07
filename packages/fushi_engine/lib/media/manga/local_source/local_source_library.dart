/// 把 Local source root（`localcomic/{manga}/...`）登记进 Library。
///
/// 关键约束（ADR 0013 / storage-layout spec）：
/// - **原地读取、不复制**：登记只写 `epub_books` 行，`extractDir` 直接指向
///   `localcomic` 里的作品目录；不碰受管书库（`fushi_books`）。
/// - **移出书架不删文件**：[removeFromLibrary] 只删行并立 `book_tombstones`；
///   删除本地文件是单独的 [deleteLocalFiles]，且必须显式 `confirmed: true`。
/// - **墓碑防复活**：普通扫描遇到已立碑的 bookKey 直接跳过，绝不重新加回。
/// - 作品身份 = 绝对文件夹路径（大小写不敏感）；目录改名/移动 = 新作品，旧行
///   保持不动（由重建索引 / 缺失状态负责展示）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_metadata.dart';

export 'package:fushi_engine/media/manga/local_source/local_source_metadata.dart';

/// 一次扫描导入的结局计数。
class LocalSourceImportReport {
  LocalSourceImportReport({
    this.added = 0,
    this.refreshed = 0,
    this.skippedTombstoned = 0,
    this.failed = 0,
    List<Object>? failures,
  }) : failures = failures ?? <Object>[];

  /// 新登记的作品数。
  final int added;

  /// 已有条目被刷新的作品数。
  final int refreshed;

  /// 因主动移出书架（墓碑）而跳过的作品数。
  final int skippedTombstoned;

  /// 读盘 / 落库失败的作品数；失败不中断其余作品。
  final int failed;

  final List<Object> failures;

  bool get isEmpty =>
      added == 0 && refreshed == 0 && skippedTombstoned == 0 && failed == 0;
}

/// 删除本地文件的结局。
enum LocalSourceDeleteReason {
  deleted,
  notConfirmed,
  notFound,
  notLocalSource,
  outsideLocalSourceRoot,
}

class LocalSourceDeleteResult {
  const LocalSourceDeleteResult(this.reason);

  final LocalSourceDeleteReason reason;

  bool get deleted => reason == LocalSourceDeleteReason.deleted;
}

/// Local source 的 Library 读写口。
class LocalSourceLibrary {
  const LocalSourceLibrary({required this.db, required this.root});

  final FushiDatabase db;

  /// Local source root（`<Content root>/localcomic`）。
  final Directory root;

  /// 扫描 [root] 的第一层目录并把每部作品登记/刷新进 Library。
  ///
  /// 已立墓碑的作品跳过（主动移出书架后不会被普通扫描复活）；单部作品失败不
  /// 中断整次扫描。只增改，不删除任何记录。
  Future<LocalSourceImportReport> importFromRoot() async {
    final List<LocalSourceManga> mangas = await scanLocalSourceRoot(root);
    final Set<String> tombstones = await db.getBookTombstoneKeys();
    int added = 0;
    int refreshed = 0;
    int skippedTombstoned = 0;
    final List<Object> failures = <Object>[];
    for (final LocalSourceManga manga in mangas) {
      final String bookKey = localSourceBookKeyFor(manga.directoryPath);
      if (tombstones.contains(bookKey)) {
        skippedTombstoned++;
        continue;
      }
      try {
        if (await _registerManga(bookKey, manga)) {
          added++;
        } else {
          refreshed++;
        }
      } on Object catch (error) {
        failures.add(error);
      }
    }
    return LocalSourceImportReport(
      added: added,
      refreshed: refreshed,
      skippedTombstoned: skippedTombstoned,
      failed: failures.length,
      failures: failures,
    );
  }

  /// 移出书架：删记录 + 立墓碑，**不删磁盘文件**。
  ///
  /// 只接受本服务登记的 Local source 条目；在线 / 受管条目返回 false。
  Future<bool> removeFromLibrary(String bookKey) async {
    final EpubBookRow? row = await db.getEpubBook(bookKey);
    if (row == null) return false;
    if (LocalSourceMetadata.tryParse(row.sourceMetadata) == null) return false;
    await db.deleteEpubBook(bookKey, tombstone: true);
    return true;
  }

  /// 「删除本地文件」——单独的用户动作，[confirmed] 必须为 true。
  ///
  /// 只允许删除 `localcomic` 之内的已登记目录；路径越界时拒绝且不动文件/记录。
  /// 删除后同样立墓碑，避免下次扫描复活空记录。
  Future<LocalSourceDeleteResult> deleteLocalFiles(
    String bookKey, {
    required bool confirmed,
  }) async {
    if (!confirmed) {
      return const LocalSourceDeleteResult(
        LocalSourceDeleteReason.notConfirmed,
      );
    }
    final EpubBookRow? row = await db.getEpubBook(bookKey);
    if (row == null) {
      return const LocalSourceDeleteResult(LocalSourceDeleteReason.notFound);
    }
    if (LocalSourceMetadata.tryParse(row.sourceMetadata) == null) {
      return const LocalSourceDeleteResult(
        LocalSourceDeleteReason.notLocalSource,
      );
    }
    final String rootCanon = p.canonicalize(root.path);
    final String dirCanon = p.canonicalize(row.extractDir);
    if (!p.isWithin(rootCanon, dirCanon)) {
      return const LocalSourceDeleteResult(
        LocalSourceDeleteReason.outsideLocalSourceRoot,
      );
    }
    await db.deleteEpubBook(bookKey, tombstone: true);
    final Directory dir = Directory(row.extractDir);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    return const LocalSourceDeleteResult(LocalSourceDeleteReason.deleted);
  }

  /// 登记或刷新一部**已扫描**的作品（Rebuild download index 的恢复分支复用
  /// 同一写入形状）。返回 true = 新建，false = 刷新。
  ///
  /// 调用方负责 tombstone 判断与「是否已经存在」的短路；这里只写 Library 行。
  Future<bool> registerScannedManga(LocalSourceManga manga) =>
      _registerManga(localSourceBookKeyFor(manga.directoryPath), manga);

  /// 登记或刷新一部已扫描的作品。返回 true = 新建，false = 刷新。
  Future<bool> _registerManga(String bookKey, LocalSourceManga manga) async {
    final EpubBookRow? existing = await db.getEpubBook(bookKey);
    final String chaptersJson =
        encodeLocalSourceChapters(<LocalSourceChapterRecord>[
          for (final LocalSourceChapter chapter in manga.chapters)
            LocalSourceChapterRecord(
              key: chapter.key,
              name: chapter.name,
              relativePath: chapter.relativePath,
            ),
        ]);
    final String? coverPath = _coverPathFor(manga);
    final String sourceMetadata = LocalSourceMetadata(
      relativePath: manga.relativePath,
    ).encode();

    if (existing == null) {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: bookKey,
          title: manga.title,
          coverPath: Value<String?>(coverPath),
          // Local source 没有必需的 manga.json；阅读器按 sourceMetadata 分流。
          epubPath: '',
          extractDir: manga.directoryPath,
          chapterCount: manga.pageCount,
          chaptersJson: chaptersJson,
          importedAt: DateTime.now().millisecondsSinceEpoch,
          format: const Value<String>('manga'),
          sourceMetadata: Value<String>(sourceMetadata),
        ),
      );
      return true;
    }

    // 刷新只覆盖内容描述；uid / importedAt / 进度 / 已读状态全部保留。
    await (db.update(
      db.epubBooks,
    )..where((t) => t.bookKey.equals(bookKey))).write(
      EpubBooksCompanion(
        title: Value<String>(manga.title),
        coverPath: Value<String?>(coverPath),
        epubPath: const Value<String>(''),
        extractDir: Value<String>(manga.directoryPath),
        chapterCount: Value<int>(manga.pageCount),
        chaptersJson: Value<String>(chaptersJson),
        format: const Value<String>('manga'),
        sourceMetadata: Value<String>(sourceMetadata),
      ),
    );
    return false;
  }

  /// 封面相对 Manga 目录：优先 `cover.jpg/jpeg/png`，否则第一个文件夹章节的
  /// 首页。CBZ 章节的页没有独立磁盘文件（封面解析只认真实文件），跳过——
  /// `cover.jpg` 约定仍由封面解析器在作品目录里兜底。
  String? _coverPathFor(LocalSourceManga manga) {
    if (manga.coverRelativePath != null) return manga.coverRelativePath;
    for (final LocalSourceChapter chapter in manga.chapters) {
      if (chapter.isArchive) continue;
      if (chapter.pages.isEmpty) continue;
      final String page = chapter.pages.first.relativePath;
      return chapter.relativePath.isEmpty
          ? page
          : '${chapter.relativePath}/$page';
    }
    return null;
  }
}

/// Local source 作品身份：绝对目录路径（小写、规范）的摘要。
///
/// 前缀 `local-` 与在线条目的 `mihon-` / `aidoku-` 区分；路径变了就是新作品
/// （ADR 0013）。大小写折叠对齐 Windows 的大小写不敏感文件系统。
String localSourceBookKeyFor(String directoryPath) {
  final String identity = p
      .canonicalize(directoryPath)
      .replaceAll('\\', '/')
      .toLowerCase();
  final String digest = sha256
      .convert(utf8.encode(identity))
      .toString()
      .substring(0, 32);
  return 'local-$digest';
}
