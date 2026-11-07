import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/library/online_manga_chapter_updates.dart';
import 'package:fushi/src/media/manga/library/manga_resume_point.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/media_cover_service.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/cover_file_writer.dart'
    show CoverImageInvalidException;
import 'package:fushi_engine/media/manga/download_library_storage.dart';

import 'package:fushi_engine/updates/update_feed_kind.dart';
import 'package:fushi/src/updates/update_feed_service.dart';

/// 从一个已就绪的 [MihonManager] 直接建服务。
///
/// 源浏览页手上本来就有 manager，没必要为了「加入书架」再绕一次 AppModel；而
/// 跨运行时的分派（书架/作品页只有 bookKey，不知道该找谁）走
/// `AppModel.onlineMangaLibraryService`。
OnlineMangaLibraryService mihonOnlineLibraryService(MihonManager manager) =>
    OnlineMangaLibraryService(
      database: manager.database,
      rootDirectory: manager.rootDirectory,
      adapter: MihonLibraryAdapter(manager),
    );

/// 在线漫画书架条目的读写口，**与运行时无关**。
///
/// v88 前这些逻辑住在 `MihonLibraryService` 里且签名上焊着 `MihonManager`，
/// 于是 Aidoku 只能瞬时浏览、进不了书架。现在唯一的运行时依赖是构造时传进来的
/// [OnlineMangaRuntimeAdapter]。
class OnlineMangaLibraryService {
  const OnlineMangaLibraryService({
    required this.database,
    required this.rootDirectory,
    required this.adapter,
    this.downloadsRootDirectory,
    this.updateFeed,
  });

  final FushiDatabase database;

  /// **旧**落盘根（`<runtimeRoot>/library/<bookKey>` 与 `reader-cache/`）。
  ///
  /// 票 04 起在线条目住 Download library（`<content>/downloads/{source}/{manga}`），
  /// 这个根只剩「顺手清掉旧 `reader-cache/`」一个用途。
  final Directory rootDirectory;

  /// Content root 下的 Download library 根（`<content>/downloads`）。
  ///
  /// null = 生产解析 [AppPaths.downloadsRootDirectory]；测试注入临时目录。
  final Directory? downloadsRootDirectory;

  final OnlineMangaRuntimeAdapter adapter;

  /// 更新提醒的投递口（v101）。可空是**刻意**的：源浏览页临时建的服务实例、
  /// 单测里的实例都不需要提醒，而「刷新出新章」这件事的判据不该因为少一个可选
  /// 依赖就走两条路径。null = 只落库不提醒。
  final UpdateFeedService? updateFeed;

  /// 书架身份。
  ///
  /// 摘要而不是明文拼接：作品 URL 会进文件路径，长度和字符集都不可控。
  ///
  /// **v88 前的推导必须逐字节保持**：`packageName NUL sourceId NUL seriesKey`，
  /// 前缀 `mihon-`。这串既是 `epub_books` 主键**也是**磁盘目录名，改一个字符就
  /// 等于把所有已入库的在线漫画变成找不到的孤儿。所以 runtime 刻意**不进**
  /// 摘要，只做前缀——`OnlineMangaRuntimeKind.mihon.wireValue == 'mihon'`，
  /// 于是 Mihon 条目的键与 v88 完全一致，而 Aidoku 用 `aidoku-` 前缀天然不与
  /// 它撞键空间。
  static String bookKeyFor({
    required OnlineMangaRuntimeKind runtime,
    required String extensionPackage,
    required String sourceId,
    required String seriesKey,
  }) => onlineMangaBookKeyFor(
    runtime: runtime,
    extensionPackage: extensionPackage,
    sourceId: sourceId,
    seriesKey: seriesKey,
  );

  static String bookKeyOf(OnlineMangaLibraryEntry entry) => bookKeyFor(
    runtime: entry.runtime,
    extensionPackage: entry.extensionPackage,
    sourceId: entry.sourceId,
    seriesKey: entry.series.key,
  );

  Future<EpubBookRow?> find(OnlineMangaLibraryEntry entry) =>
      database.getEpubBook(bookKeyOf(entry));

  /// 入库（已在库则只刷新，不重复建行）。
  Future<EpubBookRow> add(OnlineMangaLibraryEntry entry) async {
    final String bookKey = bookKeyOf(entry);
    final EpubBookRow? existing = await database.getEpubBook(bookKey);
    if (existing != null) {
      await refresh(
        bookKey: bookKey,
        existing: OnlineMangaLibraryEntry.tryParse(existing.sourceMetadata),
        series: entry.series,
        chapters: entry.chapters,
      );
      final EpubBookRow row = (await database.getEpubBook(bookKey))!;
      return row;
    }

    // Download library：`downloads/{source}/{manga}`。章节是它的直接子目录，
    // 每章自己的 `pages.json` 才是身份；书根不再写占位 manga.json。
    final Directory directory = downloadMangaDirectory(
      downloadsRoot: (await _downloadsRoot()).path,
      sourceName: await downloadSourceName(entry),
      mangaTitle: entry.series.title,
    );
    await directory.create(recursive: true);

    String? coverPath;
    final String? coverUrl = entry.series.coverUrl;
    if (coverUrl != null && coverUrl.isNotEmpty) {
      try {
        final List<int> bytes = await adapter.fetchCover(entry, coverUrl);
        // BUG-2496：未知魔数（源返回的 Cloudflare 拦截页 / HTML 错误页）直接不落盘，
        // 不再回落成 `cover.jpg`——那种文件一到渲染层就是 `Invalid image data`。
        final String? extension = _imageExtension(bytes);
        if (extension == null) {
          throw const CoverImageInvalidException(
            'online manga cover is not PNG/WebP/GIF/JPEG',
          );
        }
        final String coverFile = p.join(directory.path, 'cover$extension');
        // 收口再查一次完整性（截断 JPEG/PNG）+ 原子写 + 驱逐解码缓存。
        await MediaCoverService.applyCoverBytes(
          bytes: bytes,
          destPath: coverFile,
        );
        coverPath = p.basename(coverFile);
      } on CoverImageInvalidException catch (e) {
        ErrorLogService.instance.logDiagnostic(
          'OnlineMangaLibraryService.cover',
          e,
        );
      } on Object {
        // 封面失败不能挡住「追这部作品」。作品页仍会经源的运行时按需取图。
      }
    }

    await database.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: entry.series.title,
        author: Value<String?>(entry.series.byline),
        coverPath: Value<String?>(coverPath),
        epubPath: kDownloadPagesFileName,
        extractDir: directory.path,
        chapterCount: entry.chapters.length,
        chaptersJson: _chaptersJson(entry.chapters),
        sourceMetadata: Value<String?>(entry.encode()),
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
      ),
    );
    final EpubBookRow row = (await database.getEpubBook(bookKey))!;
    await _clearPeerDeletionTombstone(entry);
    return row;
  }

  /// 重新收下经互联来的漫画 = 撤销本机此前对它的「从所有设备删除」。
  ///
  /// 那次删除的墓碑写的是**对端键**（`ReaderFushiSource.deleteBook` 经
  /// `InterconnectMangaCatalog.peerBookKeyOf`，本机 `interconnect-…` 键对端认不出），
  /// 而 [FushiDatabase.insertEpubBook] 只按本机键清墓碑。不在这里补清，删了又收下
  /// 时那条还没推出去的墓碑会在下一轮推给 host，把用户刚重新要回来的书从 host 删掉。
  Future<void> _clearPeerDeletionTombstone(
    OnlineMangaLibraryEntry entry,
  ) async {
    if (entry.runtime != OnlineMangaRuntimeKind.interconnect) return;
    final String peerKey = entry.series.key;
    if (peerKey.isEmpty) return;
    await database.clearSyncDeletionTombstone(
      SyncTombstoneKind.book.dbValue,
      peerKey,
    );
  }

  /// 用一次刷新的结果覆盖库里的描述符。
  ///
  /// 「当前章」按 [OnlineMangaChapter.key] 重新定位而不是沿用下标：源在两次
  /// 刷新之间插了新章，下标就会指到别的章上去。
  Future<OnlineMangaLibraryEntry?> refresh({
    required String bookKey,
    required OnlineMangaLibraryEntry? existing,
    required OnlineMangaSeries series,
    required List<OnlineMangaChapter> chapters,
  }) async {
    if (existing == null) return null;
    // 「刷出来一章都没有、而库里本来有」不是一次成功的刷新，是一次没抛异常的
    // 失败：Mihon 的 `chapterListParse` 撞上 Cloudflare 拦截页时通常**返回空
    // 列表而不抛**。照单全收就会把书架里那部漫画的章节整个清空、进度条归零，
    // 而且零提示。这里不落库、抛回给调用方走正常的失败展示（横幅 + 日志），
    // 库里的旧描述符原样保留。
    if (chapters.isEmpty && existing.chapters.isNotEmpty) {
      throw const OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        'Source returned no chapters; keeping the existing list.',
      );
    }
    int? nextIndex;
    final OnlineMangaChapter? selected = existing.currentChapter;
    if (selected != null) {
      final int found = chapters.indexWhere(
        (OnlineMangaChapter item) => item.key == selected.key,
      );
      if (found >= 0) nextIndex = found;
    }
    // copyWith 而不是重新构造：订阅两位（v3）必须跟着刷新活下来。
    final OnlineMangaLibraryEntry updated = existing.copyWith(
      series: series,
      chapters: List<OnlineMangaChapter>.unmodifiable(chapters),
      currentChapterIndex: nextIndex,
      clearCurrentChapter: nextIndex == null,
    );
    await database.updateEpubBookMihonState(
      bookKey,
      sourceMetadata: updated.encode(),
      chapterCount: chapters.length,
      chaptersJson: _chaptersJson(chapters),
    );
    await _publishNewChapters(
      bookKey: bookKey,
      title: series.title,
      previous: existing.chapters,
      current: chapters,
    );
    return updated;
  }

  /// 把这次刷新新出现的章投递成更新提醒。
  ///
  /// 挂在**落库之后**：先保证库里已经是新状态，再提醒——反过来的话，提醒发出去
  /// 而落库失败，用户点进来会看到一部没有那章的书。
  Future<void> _publishNewChapters({
    required String bookKey,
    required String title,
    required List<OnlineMangaChapter> previous,
    required List<OnlineMangaChapter> current,
  }) async {
    final UpdateFeedService? feed = updateFeed;
    if (feed == null) return;
    final List<OnlineMangaChapter> fresh = newlyAppearedChapters(
      previous: previous,
      current: current,
    );
    if (fresh.isEmpty) return;
    await feed.publishBatch(UpdateFeedKind.mangaChapter, <UpdateFeedDraft>[
      for (final OnlineMangaChapter chapter in fresh)
        UpdateFeedDraft(
          kind: UpdateFeedKind.mangaChapter,
          targetKey: mangaChapterTargetKey(
            bookKey: bookKey,
            chapterKey: chapter.key,
          ),
          title: title,
          subtitle: mangaChapterDisplayName(chapter),
          detailJson: jsonEncode(<String, Object?>{
            'bookKey': bookKey,
            'chapterKey': chapter.key,
          }),
        ),
    ]);
  }

  /// 联网刷新一条书架条目，成功则落库。
  Future<OnlineMangaLibraryEntry> refreshFromSource({
    required String bookKey,
    required OnlineMangaLibraryEntry entry,
  }) async {
    final OnlineMangaRefreshResult result = await adapter.refresh(entry);
    final OnlineMangaLibraryEntry? updated = await refresh(
      bookKey: bookKey,
      existing: entry,
      series: result.series,
      chapters: result.chapters,
    );
    return updated ?? entry;
  }

  /// 记下「用户选了这一章」。
  ///
  /// **与 v88 前的关键差异**：不再顺手把 `reader_positions` 清零。那一步是
  /// 「换章即丢上一章进度」的根因——位置表一本书恒一行，清零是当时唯一能让新章
  /// 从头开始的办法。现在每章进度住 `manga_chapter_states`，恢复由阅读器按
  /// chapterKey 查表决定，选章本身不再需要破坏任何进度。
  Future<OnlineMangaLibraryEntry> selectChapter({
    required String bookKey,
    required OnlineMangaLibraryEntry entry,
    required int chapterIndex,
  }) async {
    if (chapterIndex < 0 || chapterIndex >= entry.chapters.length) {
      throw RangeError.index(chapterIndex, entry.chapters, 'chapterIndex');
    }
    final OnlineMangaLibraryEntry updated = entry.copyWith(
      currentChapterIndex: chapterIndex,
    );
    await database.updateEpubBookMihonState(
      bookKey,
      sourceMetadata: updated.encode(),
      chapterCount: updated.chapters.length,
      chaptersJson: _chaptersJson(updated.chapters),
    );
    return updated;
  }

  /// 写订阅位（设计稿 2026-09-12 §2.3）：只改 `sourceMetadata` 里的两个布尔，
  /// 章节列表 / 当前章原样。返回写回后的描述符。
  Future<OnlineMangaLibraryEntry> setSubscription({
    required String bookKey,
    required OnlineMangaLibraryEntry entry,
    required bool subscribed,
    required bool autoDownload,
  }) async {
    final OnlineMangaLibraryEntry updated = entry.copyWith(
      subscribed: subscribed,
      autoDownload: autoDownload,
    );
    await database.updateEpubBookMihonState(
      bookKey,
      sourceMetadata: updated.encode(),
      chapterCount: updated.chapters.length,
      chaptersJson: _chaptersJson(updated.chapters),
    );
    return updated;
  }

  /// 保证这条在线条目的漫画目录住在 Download library：
  /// `<content>/downloads/{source}/{manga}`，返回**当前**行。
  ///
  /// fresh-start：旧布局（`<runtimeRoot>/library` / `<content>/fushi_books`）
  /// **不搬移、不复制**，只把 `extractDir` 重指向新布局。旧章仍可由
  /// `DownloadLibraryIndex` 的只读回退打开，直到清理旧 root 的票删除它。
  ///
  /// 已在标准位置的行原样返回（零 IO 之外的一次路径比较）。
  Future<EpubBookRow> ensureBookDirectory(EpubBookRow row) async {
    final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
      row.sourceMetadata,
    );
    if (entry == null) {
      throw StateError('The library row has no online descriptor');
    }
    final Directory downloadsRoot = await _downloadsRoot();
    // 目录名不是身份：一旦漫画目录已在 Download library 里，源/漫画改名**不**
    // 重命名或重指向目录（映射与 pages.json 才是身份）。只补建丢失的空目录。
    if (p.isWithin(
      p.canonicalize(downloadsRoot.path),
      p.canonicalize(row.extractDir),
    )) {
      final Directory existing = Directory(row.extractDir);
      if (!await existing.exists()) await existing.create(recursive: true);
      return row;
    }
    final Directory target = downloadMangaDirectory(
      downloadsRoot: downloadsRoot.path,
      sourceName: await downloadSourceName(entry),
      mangaTitle: entry.series.title,
    );
    await target.create(recursive: true);
    await database.updateEpubBookContentPaths(
      row.bookKey,
      extractDir: target.path,
    );
    // 旧的阅读期页缓存对新布局毫无价值，顺手清掉——失败只记日志，不挡打开。
    final Directory staleCache = Directory(
      p.join(rootDirectory.path, 'reader-cache', 'chapters', row.bookKey),
    );
    try {
      if (await staleCache.exists()) await staleCache.delete(recursive: true);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'OnlineMangaLibraryService.cleanReaderCache',
        error,
        stack,
      );
    }
    return (await database.getEpubBook(row.bookKey)) ??
        row.copyWith(extractDir: target.path);
  }

  Future<Directory> _downloadsRoot() async {
    final Directory? injected = downloadsRootDirectory;
    if (injected != null) return injected;
    // 测试缝：大量既有测试用 `EpubStorage.debugBaseDirectoryOverride` 把书根钉在
    // 临时目录；没有 path_provider 插件时 AppPaths 解不出 Content root。把
    // Download library 派生到同一临时根的兄弟目录，测试之间仍然隔离。
    final String? legacyBase = EpubStorage.debugBaseDirectoryOverridePath;
    if (legacyBase != null) {
      return Directory(p.join(p.dirname(legacyBase), 'downloads'));
    }
    return AppPaths.downloadsRootDirectory();
  }

  /// Source 目录名：Source 显示名优先；没有显示名时退回 sourceId / runtime，
  /// 保证永远有可读且非空的目录段（同名冲突由票 05 处理）。
  Future<String> downloadSourceName(OnlineMangaLibraryEntry entry) async {
    final String? label = (await adapter.sourceLabel(entry))?.trim();
    if (label != null && label.isNotEmpty) return label;
    final String sourceId = entry.sourceId.trim();
    if (sourceId.isNotEmpty) return sourceId;
    return entry.runtime.wireValue;
  }

  /// 新读者从哪一章开始（[mangaInitialChapterIndex]）。
  static int initialChapterIndex(OnlineMangaLibraryEntry entry) =>
      mangaInitialChapterIndex(entry);

  /// 「继续阅读」落到哪一章（[continueMangaChapterIndex]）。这比直接用
  /// `currentChapterIndex` 准：那个字段只记「最后一次选了哪章」，用户在作品页点开
  /// 一章看了两眼退出来，它也会被改写。[target] 见 [MangaResumeTarget]。
  static int resumeChapterIndex(
    OnlineMangaLibraryEntry entry,
    Map<String, MangaChapterStateRow> states, {
    MangaResumeTarget target = MangaResumeTarget.furthestProgress,
  }) => continueMangaChapterIndex(entry, states, target: target);

  static String _chaptersJson(List<OnlineMangaChapter> chapters) =>
      jsonEncode(<Map<String, Object?>>[
        for (final OnlineMangaChapter chapter in chapters) chapter.toJson(),
      ]);

  /// 按魔数定封面扩展名；不是 PNG / WebP / GIF / JPEG 返回 null（调用方不落盘）。
  static String? _imageExtension(List<int> bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47) {
      return '.png';
    }
    if (bytes.length >= 12 &&
        String.fromCharCodes(bytes.skip(8).take(4)) == 'WEBP') {
      return '.webp';
    }
    if (bytes.length >= 6 && String.fromCharCodes(bytes.take(3)) == 'GIF') {
      return '.gif';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return '.jpg';
    }
    return null;
  }
}
