import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import 'package:my_comic_core/my_comic_core.dart';
import 'package:my_comic/src/media/manga/library/online_manga_chapter_updates.dart';
import 'package:my_comic/src/media/manga/library/manga_resume_point.dart';
import 'package:my_comic/src/media/manga/library/online_manga_library_entry.dart';
import 'package:my_comic/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:my_comic/src/media/manga/manga_source_language.dart';
import 'package:my_comic/src/media/manga/mihon/mihon_manager.dart';
import 'package:my_comic/src/storage/app_paths.dart';
import 'package:my_comic/src/utils/misc/error_log_service.dart';
import 'package:my_comic/src/utils/misc/trimmed_text.dart';
import 'package:my_comic/src/media/manga/download/download_identity.dart';
import 'package:my_comic/src/media/manga/download/download_library_scanner.dart';
import 'package:my_comic/src/media/manga/download/download_manga_relinker.dart';
import 'package:my_comic_engine/media/manga/book_storage.dart';
import 'package:my_comic_engine/media/manga/download_library_storage.dart';
import 'package:my_comic_engine/media/manga/local_source/local_source_layout.dart';

import 'package:my_comic_engine/updates/update_feed_kind.dart';
import 'package:my_comic/src/updates/update_feed_service.dart';

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

/// 一次联网刷新的结果。
///
/// [entry] 是**已经落库**的描述符：详情阶段的系列元数据与封面 URL 一定写回了
/// [entry]（票 06）。[chaptersError] 非空表示这次章节列表没拿到，此时
/// [entry] 里的章节是上一次成功刷新留下的旧列表，不是空列表。
class OnlineMangaRefreshOutcome {
  const OnlineMangaRefreshOutcome({
    required this.entry,
    this.chaptersError,
    this.chaptersRefreshed = true,
  });

  final OnlineMangaLibraryEntry entry;
  final OnlineMangaUnavailable? chaptersError;

  /// 章节列表是否真的刷新过。
  ///
  /// 与 [chaptersError] 不同：源返回空章节列表时详情/封面仍会落库（票 06），
  /// 但章节列表没有刷新、沿用了旧缓存；自动更新探测必须把这种情况按失败处理，
  /// 不能计入一次成功刷新，也不能拿旧章节去 diff 新章。
  final bool chaptersRefreshed;

  /// 空章节列表、沿用旧缓存时必须向调用方报告的原因。
  static const OnlineMangaUnavailable emptyChaptersError =
      OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        'Source returned no chapters; keeping the existing list.',
      );
}

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

  final MyComicDatabase database;

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

  Future<EpubBookRow?> find(OnlineMangaLibraryEntry entry) async {
    final EpubBookRow? exact = await database.getEpubBook(bookKeyOf(entry));
    if (exact != null) return exact;
    return _findSameSourceSeries(entry);
  }

  /// 占位来源条目的去重回退。
  ///
  /// 导入时扩展未安装的条目以 `mihon.unavailable` 占位包落库；扩展安装后从
  /// 来源浏览同一部作品，扩展包变成真实值，bookKey 因此不同。这里按
  /// `(运行时, 数字 sourceId, series key)` 找已是同一部作品的存量行，避免
  /// 从已安装来源再入库时出现两条书架条目。命中行原样返回，身份不改写。
  Future<EpubBookRow?> _findSameSourceSeries(
    OnlineMangaLibraryEntry entry,
  ) async {
    final String? wantedSourceId = normalizedMangaSourceId(entry.sourceId);
    if (wantedSourceId == null || entry.series.key.isEmpty) return null;
    EpubBookRow? fallback;
    for (final EpubBookRow row in await database.getAllEpubBooks()) {
      final OnlineMangaLibraryEntry? candidate =
          OnlineMangaLibraryEntry.tryParse(row.sourceMetadata);
      if (candidate == null ||
          candidate.runtime != entry.runtime ||
          candidate.series.key != entry.series.key ||
          normalizedMangaSourceId(candidate.sourceId) != wantedSourceId) {
        continue;
      }
      // 同一扩展包的候选优先（通常就是安装后第一次写出的真实身份）。
      if (candidate.extensionPackage == entry.extensionPackage) return row;
      fallback ??= row;
    }
    return fallback;
  }

  /// 入库（已在库则只刷新，不重复建行）。
  ///
  /// 显式加入书架命中已有**非书架行**时，只把同一行的 membership 翻成 true：
  /// bookKey / uid / extractDir / 章节 / 阅读进度 / 已读 / 下载映射 / History
  /// 全部原样保留。只有完全没有行时才创建新的 Library 行。
  Future<EpubBookRow> add(OnlineMangaLibraryEntry entry) async {
    final EpubBookRow? existing = await find(entry);
    if (existing == null) return _insert(entry, inLibrary: true);
    if (!existing.isInLibrary) {
      await database.updateEpubBookInLibrary(existing.bookKey, inLibrary: true);
      return (await database.getEpubBook(existing.bookKey))!;
    }
    await refresh(
      bookKey: existing.bookKey,
      existing: OnlineMangaLibraryEntry.tryParse(existing.sourceMetadata),
      series: entry.series,
      chapters: entry.chapters,
    );
    return (await database.getEpubBook(existing.bookKey))!;
  }

  /// 确保这部在线作品有一条 **Library membership=false** 的 Manga 行（票 02）。
  ///
  /// 打开在线源作品页时调用：同一作品已有行（含占位来源的同作品回退）就原样
  /// 复用，不翻转 membership、不重复建行；没有行才插入一条非书架行，章节与
  /// 来源 metadata 都来自 [entry]。标题 / 封面 / 下载目录与 [add] 共用同一条
  /// 插入路径，之后显式加入书架只翻 membership，bookKey/uid 不变。
  ///
  /// 这里**不联网刷新**：首屏章节缓存由作品页自己的刷新策略决定，打开源作品
  /// 页不该被一次全量刷新挡住。
  ///
  /// 票 02：只写数据库行，**不创建目录、不抓取封面**。目录只在下载 worker
  /// 真正开始章节下载时创建；封面只由 Cache / 远程 `series.coverUrl` 提供。
  Future<EpubBookRow> ensureNonLibrary(OnlineMangaLibraryEntry entry) async =>
      await find(entry) ?? await _insert(entry, inLibrary: false);

  /// 插入一条新的 Manga 行（bookKey 尚不存在时）。
  ///
  /// Download library：只把 `downloads/{source}/{manga}` 路径写进 `extractDir`，
  /// **不创建目录、不写封面**（票 02 惰性物化）。章节是它的直接子目录，每章
  /// 自己的 `pages.json` 才是身份；书根不再写占位 manga.json。
  /// 同名 Source / 同名 Manga 在这里解决（短源 ID / `(2)` 后缀），绝不覆盖。
  Future<EpubBookRow> _insert(
    OnlineMangaLibraryEntry entry, {
    required bool inLibrary,
  }) async {
    final String bookKey = bookKeyOf(entry);
    final _DownloadMangaDirectoryResolution resolution =
        await _resolveDownloadMangaDirectory(
          entry,
          downloadsRoot: await _downloadsRoot(),
        );
    final Directory directory = resolution.directory;

    await database.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: entry.series.title,
        author: Value<String?>(entry.series.byline),
        epubPath: kDownloadPagesFileName,
        extractDir: directory.path,
        chapterCount: entry.chapters.length,
        chaptersJson: _chaptersJson(entry.chapters),
        sourceMetadata: Value<String?>(entry.encode()),
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
        inLibrary: Value<bool>(inLibrary),
      ),
    );
    final EpubBookRow row = (await database.getEpubBook(bookKey))!;
    // 复用已有文件夹后立即重建章节映射：详情页/作品页马上显示已下载，不必等
    // 用户手动跑 Rebuild download index。
    final DownloadMangaFolderOnDisk? reusedFolder = resolution.reusedFolder;
    if (reusedFolder != null) {
      await relinkDownloadMangaFolder(
        database: database,
        row: row,
        entry: entry,
        mangaFolder: reusedFolder.directory,
        chapters: reusedFolder.chapters,
      );
    }
    await _clearPeerDeletionTombstone(entry);
    return row;
  }

  /// 重新收下经互联来的漫画 = 撤销本机此前对它的「从所有设备删除」。
  ///
  /// 那次删除的墓碑写的是**对端键**（`ReaderMyComicSource.deleteBook` 经
  /// `InterconnectMangaCatalog.peerBookKeyOf`，本机 `interconnect-…` 键对端认不出），
  /// 而 [MyComicDatabase.insertEpubBook] 只按本机键清墓碑。不在这里补清，删了又收下
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
  ///
  /// 票 06：**详情与章节解耦**。即使源这次返回空章节列表（Mihon 的
  /// `chapterListParse` 撞上 Cloudflare 拦截页时通常返回空而不抛），详情那一步
  /// 已经拿到的系列元数据与封面 URL 仍要落库；本地已有的非空章节列表原样保留，
  /// 绝不清空。旧章节没变，也就没有重链与「新章提醒」可做。
  Future<OnlineMangaLibraryEntry?> refresh({
    required String bookKey,
    required OnlineMangaLibraryEntry? existing,
    required OnlineMangaSeries series,
    required List<OnlineMangaChapter> chapters,
  }) async {
    if (existing == null) return null;
    final bool keepExistingChapters =
        chapters.isEmpty && existing.chapters.isNotEmpty;
    final List<OnlineMangaChapter> effectiveChapters = keepExistingChapters
        ? existing.chapters
        : chapters;
    int? nextIndex;
    final OnlineMangaChapter? selected = existing.currentChapter;
    if (selected != null) {
      final int found = effectiveChapters.indexWhere(
        (OnlineMangaChapter item) => item.key == selected.key,
      );
      if (found >= 0) nextIndex = found;
    }
    // copyWith 而不是重新构造：订阅两位（v3）必须跟着刷新活下来。
    final OnlineMangaLibraryEntry updated = existing.copyWith(
      series: series,
      chapters: List<OnlineMangaChapter>.unmodifiable(effectiveChapters),
      currentChapterIndex: nextIndex,
      clearCurrentChapter: nextIndex == null,
    );
    await database.updateEpubBookMihonState(
      bookKey,
      sourceMetadata: updated.encode(),
      chapterCount: effectiveChapters.length,
      chaptersJson: _chaptersJson(effectiveChapters),
    );
    if (!keepExistingChapters) {
      // 清库只删记录：重开时行可能是用「只有标题」的源页 seed 建出来的，磁盘
      // 目录已按 pages.json 身份复用，但 seed 没有章节，映射建不出来。章节表
      // 刷新后再走一次 re-link，章节列表才能立即显示已下载、删除下载无需手动
      // 重建索引。
      await _relinkDownloadFolderAfterRefresh(bookKey: bookKey, entry: updated);
      await _publishNewChapters(
        bookKey: bookKey,
        title: series.title,
        previous: existing.chapters,
        current: chapters,
      );
    }
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

  /// 章节表刷新后按当前章表重链已有下载目录（票 05）。
  ///
  /// 「清除数据库」只删记录；重新打开作品时 `_insert` 能按 `pages.json` 身份
  /// 复用磁盘目录并写 `extractDir`，但源网格 seed 往往没有章节，映射仍建不
  /// 出来。章节表拉齐后必须再 re-link 一次，批量 / 单章删除与「已下载」状态
  /// 才能直接使用，不需要用户手动运行「重建下载索引」。
  ///
  /// 只处理当前 Download library 根内、真实存在的漫画目录：`local` 原件与旧
  /// 布局路径不碰；re-link 只写映射 / extractDir，不创建、删除或重命名文件。
  Future<void> _relinkDownloadFolderAfterRefresh({
    required String bookKey,
    required OnlineMangaLibraryEntry entry,
  }) async {
    if (entry.chapters.isEmpty) return;
    final EpubBookRow? row = await database.getEpubBook(bookKey);
    if (row == null) return;
    final String extractDir = row.extractDir.trim();
    if (extractDir.isEmpty) return;
    final Directory downloadsRoot = await _downloadsRoot();
    if (!isLocalSourcePathWithinRoot(extractDir, downloadsRoot)) return;
    final Directory mangaFolder = Directory(extractDir);
    if (!await mangaFolder.exists()) return;
    try {
      await relinkDownloadMangaFolder(
        database: database,
        row: row,
        entry: entry,
        mangaFolder: mangaFolder,
      );
    } on Object catch (error, stack) {
      // 重链只是下载状态 / 删除的辅助修复；磁盘或映射异常不能让章节刷新失败。
      // 下一次刷新会幂等重试，已写下的映射保留。
      ErrorLogService.instance.log(
        'OnlineMangaLibraryService.relinkAfterRefresh',
        error,
        stack,
      );
    }
  }

  /// 打开源搜索 / 详情页时，把源当前拿到的系列描述合并回已有 Manga 行。
  ///
  /// 只写 `sourceMetadata`；章节、当前章、订阅位与阅读进度原样保留，也不联网、
  /// 不抓封面字节、不创建 Download library 目录。封面 URL 常带时效签名且源
  /// 每次搜索都会给出新地址，合并后签名过期即可自愈。
  Future<OnlineMangaLibraryEntry> mergeSeries({
    required String bookKey,
    required OnlineMangaLibraryEntry existing,
    required OnlineMangaSeries series,
  }) async {
    final OnlineMangaSeries merged = _mergedSeries(
      existing: existing.series,
      incoming: series,
    );
    if (jsonEncode(merged.toJson()) == jsonEncode(existing.series.toJson())) {
      return existing;
    }
    final OnlineMangaLibraryEntry updated = existing.copyWith(series: merged);
    await database.updateEpubBookMihonState(
      bookKey,
      sourceMetadata: updated.encode(),
      chapterCount: updated.chapters.length,
      chaptersJson: _chaptersJson(updated.chapters),
    );
    return updated;
  }

  /// 逐个字段「非空优先」：源页给的新值覆盖旧值，源页没给的（搜索网格常常只有
  /// 标题与封面）保留记录里的。身份 key 永远用已有记录，避免同源回退行被改写
  /// 身份。
  static OnlineMangaSeries _mergedSeries({
    required OnlineMangaSeries existing,
    required OnlineMangaSeries incoming,
  }) => OnlineMangaSeries(
    key: existing.key,
    title: trimmedOrNull(incoming.title) ?? existing.title,
    coverUrl: trimmedOrNull(incoming.coverUrl) ?? existing.coverUrl,
    author: trimmedOrNull(incoming.author) ?? existing.author,
    artist: trimmedOrNull(incoming.artist) ?? existing.artist,
    description: trimmedOrNull(incoming.description) ?? existing.description,
    genre: trimmedOrNull(incoming.genre) ?? existing.genre,
    raw: incoming.raw.isEmpty ? existing.raw : incoming.raw,
  );

  /// 联网刷新一条书架条目，成功则落库。
  ///
  /// 票 06：详情与章节解耦。章节阶段失败时，只要错误携带了详情阶段已经拿到的
  /// 系列描述（[OnlineMangaUnavailable.series]），就先把这份描述落库（旧章节
  /// 原样保留），再把失败作为 [OnlineMangaRefreshOutcome.chaptersError] 交回
  /// 调用方，让界面既能自愈封面，又能照常提示这次刷新没拉全。
  Future<OnlineMangaRefreshOutcome> refreshFromSource({
    required String bookKey,
    required OnlineMangaLibraryEntry entry,
  }) async {
    try {
      final OnlineMangaRefreshResult result = await adapter.refresh(entry);
      // 源返回空列表而本地已有章节：详情/封面照常落库，但章节没刷新。
      final bool chaptersRefreshed =
          !(result.chapters.isEmpty && entry.chapters.isNotEmpty);
      final OnlineMangaLibraryEntry? updated = await refresh(
        bookKey: bookKey,
        existing: entry,
        series: result.series,
        chapters: result.chapters,
      );
      return OnlineMangaRefreshOutcome(
        entry: updated ?? entry,
        chaptersRefreshed: chaptersRefreshed,
      );
    } on OnlineMangaUnavailable catch (error) {
      final OnlineMangaSeries? details = error.series;
      if (details == null) rethrow;
      // 章节为空会命中 `refresh` 的「保留旧章节」分支：只写新的系列/封面。
      final OnlineMangaLibraryEntry? updated = await refresh(
        bookKey: bookKey,
        existing: entry,
        series: details,
        chapters: const <OnlineMangaChapter>[],
      );
      return OnlineMangaRefreshOutcome(
        entry: updated ?? entry,
        chaptersError: error,
        chaptersRefreshed: false,
      );
    }
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
  ///
  /// 订阅 / 自动追更只属于 Library：书架外的非书架行不能写订阅位（更新探测与
  /// 自动下载都按 membership 过滤，写进去也永远不会生效）。
  Future<OnlineMangaLibraryEntry> setSubscription({
    required String bookKey,
    required OnlineMangaLibraryEntry entry,
    required bool subscribed,
    required bool autoDownload,
  }) async {
    final EpubBookRow? row = await database.getEpubBook(bookKey);
    if (row == null || !row.isInLibrary) {
      throw StateError(
        'Subscriptions are only available for Library manga: $bookKey',
      );
    }
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

  /// 下载侧的目录物化入口：保证这条在线条目的漫画目录住在 Download library
  /// `<content>/downloads/{source}/{manga}`，返回**当前**行。
  ///
  /// **只有下载 worker 可以在真正开始章节下载时调用**（票 02）：浏览作品页、
  /// 打开阅读器都不得调用，否则会创建空目录或把旧布局 `extractDir` 重指。
  ///
  /// fresh-start：旧布局（`<runtimeRoot>/library` / `<content>/my_comic_books`）
  /// **不搬移、不复制**，只把 `extractDir` 重指向新布局。ticket 12 已删除旧
  /// 哈希布局的只读回退：旧目录不再被读取，旧章显示 Missing，需用户自行搬移
  /// 后运行 Rebuild download index。
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
    final _DownloadMangaDirectoryResolution resolution =
        await _resolveDownloadMangaDirectory(
          entry,
          downloadsRoot: downloadsRoot,
        );
    final Directory target = resolution.directory;
    await target.create(recursive: true);
    await database.updateEpubBookContentPaths(
      row.bookKey,
      extractDir: target.path,
    );
    final DownloadMangaFolderOnDisk? reusedFolder = resolution.reusedFolder;
    if (reusedFolder != null) {
      await relinkDownloadMangaFolder(
        database: database,
        row: row,
        entry: entry,
        mangaFolder: reusedFolder.directory,
        chapters: reusedFolder.chapters,
      );
    }
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

  /// Source 表里的显示名，即使该 Source 已停用。
  ///
  /// 作品页的「来源未安装」文案要在运行时解析失败后仍能说出缺的是哪个扩展：
  /// 先按 `(extensionPackage, sourceId)` 精确匹配（不看 enabled），再按数字
  /// sourceId 在唯一扩展包内回退。同一 sourceId 命中多个包时视为歧义，返回
  /// null，不做猜测。非 Mihon 运行时没有这张表，返回 null。
  Future<String?> knownSourceName(OnlineMangaLibraryEntry entry) async {
    if (entry.runtime != OnlineMangaRuntimeKind.mihon) return null;
    final List<MangaOnlineSourceRow> sources = await database
        .getMangaOnlineSources(mediaKind: 'manga');
    for (final MangaOnlineSourceRow row in sources) {
      if (row.extensionPackage == entry.extensionPackage &&
          row.sourceId == entry.sourceId) {
        return trimmedOrNull(row.name);
      }
    }
    final String? wanted = normalizedMangaSourceId(entry.sourceId);
    if (wanted == null) return null;
    final Map<String, MangaOnlineSourceRow> byPackage =
        <String, MangaOnlineSourceRow>{};
    for (final MangaOnlineSourceRow row in sources) {
      if (normalizedMangaSourceId(row.sourceId) != wanted) continue;
      byPackage.putIfAbsent(row.extensionPackage, () => row);
    }
    if (byPackage.length != 1) return null;
    return trimmedOrNull(byPackage.values.single.name);
  }

  /// Source 目录名：Source 显示名优先；没有显示名时退回 sourceId / runtime，
  /// 保证永远有可读且非空的目录段（同名冲突由票 05 处理）。
  Future<String> downloadSourceName(OnlineMangaLibraryEntry entry) async {
    final String? label = trimmedOrNull(await adapter.sourceLabel(entry));
    if (label != null) return label;
    final String sourceId = entry.sourceId.trim();
    if (sourceId.isNotEmpty) return sourceId;
    return entry.runtime.wireValue;
  }

  /// 新下载的源目录显示名：`源名 (LANG)`；没有可区分的语言时只写源名。
  ///
  /// 语言取 [OnlineMangaSourceLanguageProvider] 报告的源语言原值并大写，保留
  /// 子标签（`zh-Hans` → `ZH-HANS`）；空、`all`、`multi` 视为无语言。互联、
  /// 旧 Aidoku 等没有语言能力的运行时同样不写后缀。目录名的净化、长度预算与
  /// 截断仍由 engine 的 [downloadSourceFolderName] 负责；`pages.json.source.name`
  /// 继续用 [downloadSourceName] 的裸源名。
  Future<String> _downloadSourceFolderLabel(
    OnlineMangaLibraryEntry entry,
  ) async {
    final String sourceName = await downloadSourceName(entry);
    final String? rawLanguage = switch (adapter) {
      final OnlineMangaSourceLanguageProvider provider =>
        provider.sourceLanguage(entry),
      _ => null,
    };
    final String language = (rawLanguage ?? '').trim();
    if (isLanguageAgnosticSourceLanguage(language)) return sourceName;
    return '$sourceName (${language.toUpperCase()})';
  }

  /// 决定这本 Manga 在 Download library 里的目录（不创建）。
  ///
  /// 目录名不是身份，但必须先保证同一路径上不会住进两个不同 Source / 两本不同
  /// Manga（Windows 文件系统大小写不敏感）：
  ///
  /// - Source：同一 Source 复用已建立的目录；显示名被**另一个** Source 占用时
  ///   追加 `[短源 ID]`；同一显示名只有大小写不同也算占用。
  /// - Manga：先按 `pages.json` 下载身份复用已有漫画文件夹（目录或 `.cbz`）：
  ///   恰好一个匹配 → 复用；多个匹配 → 不猜，回落到冲突后缀；无 manifest →
  ///   保持原有 ` (2)`、` (3)`… 安全规则。磁盘上已有但未入库的非空目录同样
  ///   视为占用（绝不覆盖用户已有内容）。
  ///
  /// 源/漫画改名不会走到这里重命名——行已存在时 [add] 只刷新；[ensureBookDirectory]
  /// 只处理还没住进 Download library 的旧行。
  Future<_DownloadMangaDirectoryResolution> _resolveDownloadMangaDirectory(
    OnlineMangaLibraryEntry entry, {
    required Directory downloadsRoot,
  }) async {
    // 用 normalize 而不是 canonicalize：后者在 Windows 上会整串小写，写进
    // extractDir 的用户可见目录就丢了大小写。
    final String rootPath = p.normalize(downloadsRoot.path);
    final DownloadSourceIdentity sourceIdentity =
        DownloadSourceIdentity.fromEntry(entry);
    final List<_DownloadLibraryClaim> claims = <_DownloadLibraryClaim>[];
    for (final EpubBookRow row in await database.getAllEpubBooks()) {
      final String directory = p.normalize(row.extractDir);
      if (!_isInsideDirectory(directory, rootPath)) continue;
      final List<String> segments = p.split(
        p.relative(directory, from: rootPath),
      );
      if (segments.isEmpty) continue;
      final OnlineMangaLibraryEntry? claimed = OnlineMangaLibraryEntry.tryParse(
        row.sourceMetadata,
      );
      claims.add(
        _DownloadLibraryClaim(
          sourceFolder: segments.first,
          mangaFolder: segments.length > 1 ? segments[1] : null,
          sourceIdentity: claimed == null
              ? null
              : DownloadSourceIdentity.fromEntry(claimed),
          mangaTitle: row.title,
        ),
      );
    }
    // 作品被移出书架时文件与目录保留，`epub_books` 行却没了。若只信数据库，
    // 另一部同名 Source 会直接复用旧 Source 的目录。这里补扫磁盘上还没有
    // 稳定身份声明的 source 目录：任一 `pages.json`（含 `.cbz` 内）能证明该
    // 目录属于哪个 Source。读不到稳定身份的目录仍按旧行为处理（复用/靠 manga
    // 目录名去重），不凭空猜测归属。
    final Set<String> identityClaimedFolders = <String>{
      for (final _DownloadLibraryClaim claim in claims)
        if (claim.sourceIdentity != null) claim.sourceFolder.toLowerCase(),
    };
    final Map<String, Set<DownloadSourceIdentity>> diskSourceIdentities =
        await _diskSourceIdentities(
          rootPath,
          skipFolderNames: identityClaimedFolders,
        );
    for (final MapEntry<String, Set<DownloadSourceIdentity>> disk
        in diskSourceIdentities.entries) {
      for (final DownloadSourceIdentity diskIdentity in disk.value) {
        claims.add(
          _DownloadLibraryClaim(
            sourceFolder: disk.key,
            mangaFolder: null,
            sourceIdentity: diskIdentity,
            mangaTitle: '',
          ),
        );
      }
    }

    final String sourceFolderLabel = await _downloadSourceFolderLabel(entry);
    final int sourceBudget = downloadLibrarySegmentBudget(
      rootPath,
      pathReserve:
          1 +
          kDownloadLibraryStagingPathReserve +
          kDownloadLibraryMinChildPathBudget,
    );
    final String baseSourceFolder = downloadSourceFolderName(
      downloadsRoot: rootPath,
      sourceName: sourceFolderLabel,
    );

    // 同一 Source 已经有目录（含此前冲突后加的短后缀）就复用它：目录名不稳定
    // 会让同一 Source 的下载散落到多个文件夹。
    String? sourceFolder;
    for (final _DownloadLibraryClaim claim in claims) {
      final DownloadSourceIdentity? claimIdentity = claim.sourceIdentity;
      if (claimIdentity != null && claimIdentity.matches(sourceIdentity)) {
        sourceFolder = claim.sourceFolder;
        break;
      }
    }
    if (sourceFolder == null) {
      final bool baseClaimedByOther = claims.any(
        (_DownloadLibraryClaim claim) =>
            claim.sourceIdentity != null &&
            !claim.sourceIdentity!.matches(sourceIdentity) &&
            _sameFolderName(claim.sourceFolder, baseSourceFolder),
      );
      sourceFolder = baseClaimedByOther
          ? fitDownloadLibrarySegmentWithSuffix(
              base: baseSourceFolder,
              // 冲突后缀的哈希沿用旧口径（runtime + 扩展包 + 原始 sourceId），
              // 避免同一 sourceId 的不同扩展包算出同一个后缀而互撞。
              suffix:
                  ' [${downloadLibraryShortHash('${sourceIdentity.runtimeWire}\u0000${sourceIdentity.extensionPackage}\u0000${sourceIdentity.sourceId}')}]',
              maxLength: sourceBudget,
            )
          : baseSourceFolder;
    }

    final String sourceDirPath = p.join(rootPath, sourceFolder);
    final List<DownloadMangaFolderOnDisk> diskFolders =
        await scanDownloadSourceFolders(Directory(sourceDirPath));

    // 身份优先：目录名不是身份，manifest 才能证明文件夹属于这部作品。
    final DownloadMangaFolderIdentityMatch identityMatch =
        matchDownloadMangaFolderByIdentity(
          diskFolders,
          MangaDownloadIdentity.ofEntry(entry),
        );
    if (identityMatch.folder != null) {
      return _DownloadMangaDirectoryResolution(
        directory: identityMatch.folder!.directory,
        reusedFolder: identityMatch.folder,
      );
    }
    // 多个 manifest 匹配：不猜，继续走下面的冲突后缀；已存在的目录一个都
    // 不改名、不删除。

    final String baseMangaFolder = downloadMangaFolderName(
      sourceDirPath: sourceDirPath,
      title: entry.series.title,
    );

    // 同名共享：同一 Source 下标题完全相同的不同作品共用同一个漫画目录
    // （Mihon 做法），不因身份不同生成 `(2)`。只有「标题完全相同」才共享：
    // 标题不同、仅净化后同名仍走冲突后缀。
    // 证据顺序：磁盘 manifest 优先（目录可能已被用户改名），没有可读 manifest
    // 时回退到库里同 Source 同标题的行（同标题作品还没开始下载，惰性物化）。
    final String entryTitle = entry.series.title.trim();
    if (entryTitle.isNotEmpty && !identityMatch.ambiguous) {
      final List<DownloadMangaFolderOnDisk> sharedOnDisk =
          <DownloadMangaFolderOnDisk>[
            for (final DownloadMangaFolderOnDisk folder in diskFolders)
              if (folder.manifests.any(
                (MangaPagesManifest manifest) =>
                    manifest.mangaTitle.trim() == entryTitle &&
                    DownloadSourceIdentity.fromManifest(
                      manifest,
                    ).matches(sourceIdentity),
              ))
                folder,
          ];
      if (sharedOnDisk.length == 1) {
        final DownloadMangaFolderOnDisk shared = sharedOnDisk.single;
        return _DownloadMangaDirectoryResolution(
          directory: shared.directory,
          reusedFolder: shared,
        );
      }
      final List<_DownloadLibraryClaim> sharedClaims = <_DownloadLibraryClaim>[
        for (final _DownloadLibraryClaim claim in claims)
          if (claim.mangaFolder != null &&
              _sameFolderName(claim.sourceFolder, sourceFolder) &&
              (claim.sourceIdentity == null ||
                  claim.sourceIdentity!.matches(sourceIdentity)) &&
              claim.mangaTitle.trim() == entryTitle)
            claim,
      ];
      if (sharedClaims.isNotEmpty) {
        final _DownloadLibraryClaim preferred = sharedClaims.firstWhere(
          (_DownloadLibraryClaim claim) =>
              _sameFolderName(claim.mangaFolder!, baseMangaFolder),
          orElse: () => sharedClaims.first,
        );
        final String sharedFolderName = preferred.mangaFolder!;
        DownloadMangaFolderOnDisk? sharedFolder;
        for (final DownloadMangaFolderOnDisk folder in diskFolders) {
          if (_sameFolderName(folder.mangaFolderName, sharedFolderName)) {
            sharedFolder = folder;
            break;
          }
        }
        return _DownloadMangaDirectoryResolution(
          directory: Directory(p.join(sourceDirPath, sharedFolderName)),
          reusedFolder: sharedFolder,
        );
      }
    }

    final Set<String> claimedMangaFolders = <String>{
      for (final _DownloadLibraryClaim claim in claims)
        if (claim.mangaFolder != null &&
            _sameFolderName(claim.sourceFolder, sourceFolder))
          claim.mangaFolder!.toLowerCase(),
    };
    final Set<String> diskMangaFolders = <String>{
      for (final DownloadMangaFolderOnDisk folder in diskFolders)
        folder.mangaFolderName.toLowerCase(),
    };
    final String mangaFolder = await uniqueDownloadLibraryFolderName(
      base: baseMangaFolder,
      isTaken: (String candidate) async =>
          claimedMangaFolders.contains(candidate.toLowerCase()) ||
          diskMangaFolders.contains(candidate.toLowerCase()),
      maxLength: downloadLibrarySegmentBudget(
        sourceDirPath,
        pathReserve: kDownloadLibraryStagingPathReserve,
      ),
    );
    return _DownloadMangaDirectoryResolution(
      directory: Directory(p.join(sourceDirPath, mangaFolder)),
    );
  }

  /// Windows 大小写不敏感：目录名比较统一转小写。
  static bool _sameFolderName(String a, String b) =>
      a.toLowerCase() == b.toLowerCase();

  static bool _isInsideDirectory(String path, String root) {
    final String normalizedPath = path.toLowerCase();
    final String normalizedRoot = root.toLowerCase();
    if (normalizedPath == normalizedRoot) return false;
    final String prefix = normalizedRoot.endsWith(p.separator)
        ? normalizedRoot
        : '$normalizedRoot${p.separator}';
    return normalizedPath.startsWith(prefix);
  }

  /// 磁盘上各 source 目录能从 `pages.json`（含 `.cbz` 内）证明的 Source
  /// 身份集合。
  ///
  /// 只看 `downloads/<source>/<manga>/<chapter>` 的第一个可解析 manifest 即停
  /// （source 级的归属只需要一处证据）。[skipFolderNames] 是已经有数据库身份
  /// 声明的目录（小写），无需再读盘。目录读不了按没有身份处理，不让一次冲突
  /// 解析失败。
  static Future<Map<String, Set<DownloadSourceIdentity>>> _diskSourceIdentities(
    String rootPath, {
    required Set<String> skipFolderNames,
  }) async {
    final Map<String, Set<DownloadSourceIdentity>> result =
        <String, Set<DownloadSourceIdentity>>{};
    for (final Directory sourceDir in await listDownloadChildDirectories(
      Directory(rootPath),
    )) {
      final String folderName = p.basename(sourceDir.path);
      if (skipFolderNames.contains(folderName.toLowerCase())) continue;
      final Set<DownloadSourceIdentity> identities = <DownloadSourceIdentity>{};
      for (final Directory mangaDir in await listDownloadChildDirectories(
        sourceDir,
      )) {
        final MangaPagesManifest? manifest =
            await readFirstDownloadMangaManifest(mangaDir);
        if (manifest == null) continue;
        identities.add(DownloadSourceIdentity.fromManifest(manifest));
        break;
      }
      result[folderName] = identities;
    }
    return result;
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
}

/// `_resolveDownloadMangaDirectory` 的结果：目录，以及它是否由磁盘 manifest
/// 证明身份后复用（复用后要立刻重建章节映射）。
class _DownloadMangaDirectoryResolution {
  const _DownloadMangaDirectoryResolution({
    required this.directory,
    this.reusedFolder,
  });

  final Directory directory;

  /// 命中的已有漫画文件夹；null = 新建（或按冲突后缀命名）。
  final DownloadMangaFolderOnDisk? reusedFolder;
}

/// 一条已入库 Manga 对 Download library 目录段的占用。
class _DownloadLibraryClaim {
  const _DownloadLibraryClaim({
    required this.sourceFolder,
    required this.mangaFolder,
    required this.sourceIdentity,
    required this.mangaTitle,
  });

  final String sourceFolder;
  final String? mangaFolder;

  /// null = 该行的描述符不可解析（例如本地条目）；不作为同源复用的依据。
  final DownloadSourceIdentity? sourceIdentity;

  /// 该行登记的作品标题；同 Source 同标题的不同作品共享漫画目录。
  final String mangaTitle;
}
