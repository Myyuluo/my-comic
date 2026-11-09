/// 漫画一级「历史」页的数据层：身份、快照与读写。
///
/// 历史页的唯一数据源是 `media_open_history`（ADR 0018）；阅读器在**打开章节
/// 进入阅读器时**调用 [recordMangaHistoryOpened]，这里只负责把「这部漫画是谁」
/// 落成一行、以及把行还原成历史页能展示 / 打开的条目。
///
/// 身份规则（每部 Manga 一条，PK = mediaSource + mediaId）：
/// - 在线作品：Source = 运行时 + 扩展包 + 源 id，作品 id = 源内作品 key（Mihon 即
///   作品 URL）。**不拿 Library bookKey 当身份**：同一作品从未入书架到加入书架
///   始终是同一条；移出书架后历史仍在，可凭快照回到来源作品页。
/// - Local source：Source = 伪源 [kMangaHistoryLocalSource]，作品 id = 相对
///   Local source root 的路径。
/// - 本地导入的漫画卷（无在线 / 本地源描述符）：Source = `reader_manga`，
///   作品 id = `hoshi://book/<bookKey>`。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_metadata.dart';

import 'package:fushi/src/media/display_title.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/sources/manga_fushi_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/types/reader_media_type.dart';

/// Local source 作品在历史身份里占的伪源。
///
/// Local source 没有在线运行时，作品身份是相对路径（见 `LocalSourceMetadata`）。
const String kMangaHistoryLocalSource = 'local_source';

/// 在线作品历史身份的前缀；后面跟 `[runtime, extensionPackage, sourceId]` 的
/// JSON 数组，避免扩展包 / 源 id 里出现分隔符时撞键。
const String kMangaHistoryOnlineSourcePrefix = 'manga_online:';

/// 漫画历史的一行身份。
class MangaHistoryIdentity {
  const MangaHistoryIdentity(this.mediaSource, this.mediaId);

  final String mediaSource;
  final String mediaId;

  /// `media_open_history` 的主键语义。
  String get key => '$mediaSource\u0000$mediaId';
}

/// 在线作品的稳定 Source 身份（运行时 + 扩展包 + 源 id）。
String mangaHistoryOnlineSourceKey(OnlineMangaLibraryEntry entry) =>
    '$kMangaHistoryOnlineSourcePrefix'
    '${jsonEncode(<String>[entry.runtime.wireValue, entry.extensionPackage, entry.sourceId])}';

MangaHistoryIdentity mangaHistoryIdentityForOnline(
  OnlineMangaLibraryEntry entry,
) => MangaHistoryIdentity(mangaHistoryOnlineSourceKey(entry), entry.series.key);

/// 一条 Library 行的历史身份；非漫画 / 无身份返回 null。
MangaHistoryIdentity? mangaHistoryIdentityForBook(EpubBookRow row) {
  final OnlineMangaLibraryEntry? online = OnlineMangaLibraryEntry.tryParse(
    row.sourceMetadata,
  );
  if (online != null) return mangaHistoryIdentityForOnline(online);
  final LocalSourceMetadata? local = LocalSourceMetadata.tryParse(
    row.sourceMetadata,
  );
  if (local != null) {
    return MangaHistoryIdentity(kMangaHistoryLocalSource, local.relativePath);
  }
  if (BookFormat.parseOrEpub(row.format) != BookFormat.manga) return null;
  return MangaHistoryIdentity(
    MangaFushiSource.kUniqueKey,
    ReaderFushiSource.mediaIdentifierFor(row.bookKey),
  );
}

/// 这一行是不是漫画历史（与 EPUB / 视频 / 音频历史共表，按 Source 区分）。
bool isMangaHistorySource(String mediaSource) =>
    mediaSource == MangaFushiSource.kUniqueKey ||
    mediaSource == kMangaHistoryLocalSource ||
    mediaSource.startsWith(kMangaHistoryOnlineSourcePrefix);

/// 在线作品的来源描述（快照 / 重开来源作品页所需的全部载荷）。
class MangaHistoryOnlineRef {
  const MangaHistoryOnlineRef({
    required this.runtime,
    required this.extensionPackage,
    required this.sourceId,
    required this.seriesKey,
    required this.raw,
    this.coverUrl,
  });

  factory MangaHistoryOnlineRef.fromEntry(OnlineMangaLibraryEntry entry) =>
      MangaHistoryOnlineRef(
        runtime: entry.runtime,
        extensionPackage: entry.extensionPackage,
        sourceId: entry.sourceId,
        seriesKey: entry.series.key,
        raw: entry.series.raw,
        coverUrl: entry.series.coverUrl,
      );

  final OnlineMangaRuntimeKind runtime;
  final String extensionPackage;
  final String sourceId;

  /// 源内作品 id（Mihon 即作品 URL）。
  final String seriesKey;
  final Map<String, Object?> raw;
  final String? coverUrl;

  Map<String, Object?> toJson() => <String, Object?>{
    'runtime': runtime.wireValue,
    'extensionPackage': extensionPackage,
    'sourceId': sourceId,
    'seriesKey': seriesKey,
    // 作品 URL。Mihon 的 seriesKey 就是作品页 URL；互联对端是远端 bookKey，
    // 两者都保留同一个值，读取方只认 seriesKey。
    'url': seriesKey,
    if (coverUrl != null) 'coverUrl': coverUrl,
    'raw': raw,
  };

  static MangaHistoryOnlineRef? fromJson(Map<String, Object?> json) {
    final OnlineMangaRuntimeKind? runtime = OnlineMangaRuntimeKind.fromWire(
      json['runtime']?.toString(),
    );
    final String seriesKey =
        json['seriesKey']?.toString() ?? json['url']?.toString() ?? '';
    if (runtime == null || seriesKey.isEmpty) return null;
    final Object? raw = json['raw'];
    return MangaHistoryOnlineRef(
      runtime: runtime,
      extensionPackage: json['extensionPackage']?.toString() ?? '',
      sourceId: json['sourceId']?.toString() ?? '',
      seriesKey: seriesKey,
      raw: raw is Map<Object?, Object?>
          ? raw.cast<String, Object?>()
          : const <String, Object?>{},
      coverUrl: json['coverUrl']?.toString(),
    );
  }

  /// 重新打开来源作品页用的 seed（章节留空，由作品页进页后自己拉）。
  OnlineMangaLibraryEntry seed({required String title}) =>
      OnlineMangaLibraryEntry(
        runtime: runtime,
        extensionPackage: extensionPackage,
        sourceId: sourceId,
        series: OnlineMangaSeries(
          key: seriesKey,
          title: title,
          coverUrl: coverUrl,
          raw: raw,
        ),
        chapters: const <OnlineMangaChapter>[],
      );
}

/// Mihon 备份里的章节级历史载荷（`snapshot_json.mihon_history`）。
///
/// Mihon 的 History 按章节记录；MyComic 的历史行只到 Manga 粒度，因此最近阅读
/// 的章节 URL、阅读时间与阅读时长随快照一起保存，导出时原样写回备份。
class MangaHistoryMihonEntry {
  const MangaHistoryMihonEntry({
    required this.chapterUrl,
    required this.lastRead,
    required this.readDuration,
  });

  final String chapterUrl;
  final int lastRead;
  final int readDuration;

  Map<String, Object?> toJson() => <String, Object?>{
    'chapter_url': chapterUrl,
    'read_at': lastRead,
    'read_duration': readDuration,
  };

  static MangaHistoryMihonEntry? fromJson(Object? raw) {
    if (raw is! Map<Object?, Object?>) return null;
    final Map<String, Object?> json = raw.cast<String, Object?>();
    final String chapterUrl = json['chapter_url']?.toString().trim() ?? '';
    if (chapterUrl.isEmpty) return null;
    final Object? lastRead = json['read_at'];
    final Object? readDuration = json['read_duration'];
    return MangaHistoryMihonEntry(
      chapterUrl: chapterUrl,
      lastRead: lastRead is num ? lastRead.toInt() : 0,
      readDuration: readDuration is num ? readDuration.toInt() : 0,
    );
  }
}

/// 从任意漫画历史快照 JSON 读取 `mihon_history`。
///
/// 阅读器写的快照带 `mangaHistory` 标记；旧导入路径写的书架历史是裸对象。
/// 两种形状都从这里读，导出端不再各自解析私有字段。
MangaHistoryMihonEntry? mangaHistoryMihonEntryFromJson(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map<Object?, Object?>) return null;
    return MangaHistoryMihonEntry.fromJson(decoded['mihon_history']);
  } on Object {
    return null;
  }
}

/// `media_open_history.snapshot_json` 里漫画历史的展示 / 重开载荷。
///
/// 列化字段（source / id / openedAt）不在这里；标题、封面与来源身份随行走，
/// 让「未入书架 / 已移出书架」的作品也能显示并回到来源作品页。
class MangaHistorySnapshot {
  const MangaHistorySnapshot({
    required this.title,
    this.author,
    this.imageUrl,
    this.bookKey,
    this.localRelativePath,
    this.online,
    this.mihonHistory,
  });

  static const String kind = 'manga-history';

  final String title;
  final String? author;

  /// 封面（`file://` 本地落盘封面优先，否则远端 URL）。
  final String? imageUrl;
  final String? bookKey;
  final String? localRelativePath;
  final MangaHistoryOnlineRef? online;

  /// Mihon 备份中的最近一条章节级历史（可选）。
  final MangaHistoryMihonEntry? mihonHistory;

  Map<String, Object?> toJson() => <String, Object?>{
    'title': title,
    if (author != null) 'author': author,
    if (imageUrl != null) 'imageUrl': imageUrl,
    if (mihonHistory != null) 'mihon_history': mihonHistory!.toJson(),
    'mangaHistory': <String, Object?>{
      'kind': kind,
      if (bookKey != null) 'bookKey': bookKey,
      if (localRelativePath != null) 'localRelativePath': localRelativePath,
      if (online != null) 'online': online!.toJson(),
    },
  };

  static MangaHistorySnapshot? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<Object?, Object?>) return null;
      final Map<String, Object?> json = decoded.cast<String, Object?>();
      final Object? marker = json['mangaHistory'];
      if (marker is! Map<Object?, Object?>) return null;
      final Map<String, Object?> history = marker.cast<String, Object?>();
      if (history['kind']?.toString() != kind) return null;
      final Object? online = history['online'];
      return MangaHistorySnapshot(
        title: json['title']?.toString() ?? '',
        author: json['author']?.toString(),
        imageUrl: json['imageUrl']?.toString(),
        bookKey: history['bookKey']?.toString(),
        localRelativePath: history['localRelativePath']?.toString(),
        online: online is Map<Object?, Object?>
            ? MangaHistoryOnlineRef.fromJson(online.cast<String, Object?>())
            : null,
        mihonHistory: MangaHistoryMihonEntry.fromJson(json['mihon_history']),
      );
    } on Object {
      return null;
    }
  }
}

/// 历史页展示 / 打开一条记录所需的解析结果。
class MangaHistoryEntry {
  const MangaHistoryEntry({
    required this.mediaSource,
    required this.mediaId,
    required this.openedAt,
    required this.title,
    this.bookKey,
    this.coverFilePath,
    this.coverUrl,
    this.snapshot,
  });

  final String mediaSource;
  final String mediaId;
  final int openedAt;

  /// 显示标题：命中 Library 时是 Library 的最新标题（含用户改名），否则是快照。
  final String title;

  /// 命中 Library 时的 bookKey；为 null = 未入书架 / 已移出书架。
  final String? bookKey;
  final String? coverFilePath;
  final String? coverUrl;
  final MangaHistorySnapshot? snapshot;

  String get key => '$mediaSource\u0000$mediaId';

  MangaHistoryOnlineRef? get online => snapshot?.online;
}

/// 读全部漫画历史（`openedAt` 倒序，由数据库查询保证；日期分组由历史页负责）。
Future<List<MangaHistoryEntry>> loadMangaHistory(FushiDatabase db) async {
  final List<MediaOpenHistoryRow> rows = await db.getAllMediaOpenHistory();
  final List<EpubBookRow> books = await db.getAllEpubBooks();
  final Map<String, EpubBookRow> byIdentity = <String, EpubBookRow>{};
  for (final EpubBookRow book in books) {
    final MangaHistoryIdentity? identity = mangaHistoryIdentityForBook(book);
    if (identity != null) byIdentity[identity.key] = book;
  }

  final List<MangaHistoryEntry> entries = <MangaHistoryEntry>[];
  for (final MediaOpenHistoryRow row in rows) {
    if (!isMangaHistorySource(row.mediaSource)) continue;
    final MangaHistorySnapshot? snapshot = MangaHistorySnapshot.tryParse(
      row.snapshotJson,
    );
    final EpubBookRow? book =
        byIdentity[MangaHistoryIdentity(row.mediaSource, row.mediaId).key];
    String? coverFilePath;
    String? coverUrl;
    if (book != null) {
      // Library 最新信息优先：标题走用户改名覆盖，封面走本地落盘文件。
      coverFilePath = ReaderFushiSource.resolveCoverFilePath(
        extractDir: book.extractDir,
        coverPath: book.coverPath,
      );
    } else {
      final String? imageUrl = snapshot?.imageUrl;
      if (imageUrl != null && imageUrl.startsWith('file://')) {
        final String? path = Uri.tryParse(imageUrl)?.toFilePath();
        if (mangaHistoryCoverFileExists(path)) {
          coverFilePath = path;
        } else {
          // 作品被移出书架 / 文件被清理：回退快照里的来源封面 URL。
          coverUrl = snapshot?.online?.coverUrl;
        }
      } else {
        coverUrl = imageUrl ?? snapshot?.online?.coverUrl;
      }
    }
    final String snapshotTitle = snapshot?.title.trim() ?? '';
    entries.add(
      MangaHistoryEntry(
        mediaSource: row.mediaSource,
        mediaId: row.mediaId,
        openedAt: row.openedAt,
        title: book != null
            ? displayTitleForBook(bookKey: book.bookKey, rawTitle: book.title)
            : (snapshotTitle.isNotEmpty ? snapshotTitle : row.mediaId),
        bookKey: book?.bookKey,
        coverFilePath: coverFilePath,
        coverUrl: coverUrl,
        snapshot: snapshot,
      ),
    );
  }
  return entries;
}

/// 打开章节进入阅读器时写入 / 更新一条漫画历史。
///
/// 每部 Manga 一条：PK 命中时只刷新 `openedAt`（置顶）。History 不设条数
/// 上限：这里不调用 `trimMediaHistory`，旧记录不会因读得多而被静默丢弃。
/// 调用方负责无痕阅读跳过（`AppModel.incognitoReading` / `ReaderHistoryPolicy`）
/// 与「只打开详情页不写」——本函数只被阅读器在真正装载章节时调用。
Future<void> recordMangaHistoryOpened({
  required FushiDatabase db,
  required EpubBookRow row,
  OnlineMangaLibraryEntry? onlineEntry,
}) async {
  final MangaHistoryIdentity? identity = mangaHistoryIdentityForBook(row);
  if (identity == null) return;

  final LocalSourceMetadata? local = LocalSourceMetadata.tryParse(
    row.sourceMetadata,
  );
  final String? localCover = ReaderFushiSource.resolveCoverFilePath(
    extractDir: row.extractDir,
    coverPath: row.coverPath,
  );
  final String? imageUrl = localCover != null
      ? Uri.file(localCover).toString()
      : onlineEntry?.series.coverUrl;

  final MangaHistorySnapshot snapshot = MangaHistorySnapshot(
    title: row.title,
    author: row.author,
    imageUrl: imageUrl,
    bookKey: row.bookKey,
    localRelativePath: local?.relativePath,
    online: onlineEntry == null
        ? null
        : MangaHistoryOnlineRef.fromEntry(onlineEntry),
  );

  await db.upsertMediaOpenHistory(
    MediaOpenHistoryCompanion(
      mediaType: Value<String>(ReaderMediaType.instance.uniqueKey),
      mediaSource: Value<String>(identity.mediaSource),
      mediaId: Value<String>(identity.mediaId),
      openedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
      position: const Value<int>(0),
      duration: const Value<int>(0),
      snapshotJson: Value<String>(jsonEncode(snapshot.toJson())),
    ),
  );
}

/// 删除整部作品（连同落盘文件）时级联清理它的历史行（票 10）。
///
/// 历史身份是「Source + 作品 id」，作品行一删就再没有可回退的续读目标；只留
/// 快照会变成点开即失败的记录。仅移出书架（文件保留）的路径不调用本函数。
/// 非漫画行返回 null 身份，级联自然跳过。
Future<void> deleteMangaHistoryForBook(
  FushiDatabase db,
  EpubBookRow row,
) async {
  final MangaHistoryIdentity? identity = mangaHistoryIdentityForBook(row);
  if (identity == null) return;
  await db.deleteMediaOpenHistory(identity.mediaSource, identity.mediaId);
}

/// 删除一条漫画历史（只删 `media_open_history` 行，不动阅读数据）。
Future<void> deleteMangaHistoryEntry(
  FushiDatabase db,
  MangaHistoryEntry entry,
) => db.deleteMediaOpenHistory(entry.mediaSource, entry.mediaId);

/// 清空全部漫画历史（只删漫画来源行；EPUB / 视频等其它媒体历史保留）。
///
/// 只清历史记录：Reading progress、章节 `readAt`、书级完成标记与书架状态都不在
/// 本函数的作用范围（ADR 0018）。
Future<int> clearMangaHistory(FushiDatabase db) async {
  final List<MediaOpenHistoryRow> rows = await db.getAllMediaOpenHistory();
  int deleted = 0;
  for (final MediaOpenHistoryRow row in rows) {
    if (!isMangaHistorySource(row.mediaSource)) continue;
    deleted += await db.deleteMediaOpenHistory(row.mediaSource, row.mediaId);
  }
  return deleted;
}

/// 历史页封面是否是一个仍然存在的本地文件。
bool mangaHistoryCoverFileExists(String? path) {
  if (path == null || path.isEmpty) return false;
  try {
    return File(path).existsSync();
  } on Object {
    return false;
  }
}
