import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_metadata.dart';

import 'package:fushi/src/media/manga/history/manga_history.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/utils/misc/trimmed_text.dart';

/// 清理数据库的三个阶段；进度框按它显示当前在做什么。
enum MangaDatabaseClearStep { works, history, readingState }

/// 一个有待清理内容的 Source（或本地伪源）及其非书架作品计数。
enum MangaDatabaseClearSourceKind {
  /// 在线漫画 Source（Mihon / 互联等运行时）。
  online,

  /// Local source（`local` 目录）中的作品。
  localSource,

  /// 无在线 / Local source 描述符的本地导入漫画卷。
  imported,
}

/// 清理确认框列出的一行 Source。
///
/// 计数在打开对话框时一次算好，勾选 Source / 切换保留开关只做本地加减，
/// 不再反复查库。
class MangaDatabaseClearSource {
  const MangaDatabaseClearSource({
    required this.key,
    required this.kind,
    required this.nonLibraryWorks,
    required this.readWorks,
    required this.historyEntries,
    required this.readHistoryEntries,
    this.name,
    this.runtime,
    this.sourceId = '',
  });

  /// 稳定的 Source 身份（同一 Source 的占位扩展包与真实扩展包合并）。
  final String key;

  final MangaDatabaseClearSourceKind kind;

  /// Source 显示名：已安装 Source 表名称，或导入条目里的来源名。
  final String? name;

  /// 在线运行时；本地伪源为 null。
  final OnlineMangaRuntimeKind? runtime;

  /// 数字 sourceId（在线 Source 的稳定身份）；本地伪源为空。
  final String sourceId;

  /// 该 Source 下 membership=false 的漫画作品数。
  final int nonLibraryWorks;

  /// 上述作品中「有已读章节或阅读进度」的数量；开关开启时保留。
  final int readWorks;

  /// 属于上述作品的 History 行数（含旧版 `reader_manga` 身份的行）。
  final int historyEntries;

  /// 属于 [readWorks] 的 History 行数；开关开启时随作品保留。
  final int readHistoryEntries;

  /// 按「保留有阅读记录的作品」开关计算将删除的作品数。
  int worksToDelete({required bool keepRead}) =>
      keepRead ? nonLibraryWorks - readWorks : nonLibraryWorks;

  /// 按开关计算将删除的 History 行数。
  int historyToDelete({required bool keepRead}) =>
      keepRead ? historyEntries - readHistoryEntries : historyEntries;
}

/// 待删除（或已删除）的数量。
class MangaDatabaseClearCounts {
  const MangaDatabaseClearCounts({
    required this.works,
    required this.historyEntries,
    required this.readingStateRows,
  });

  /// 本次清理删除的 membership=false 漫画作品数。
  final int works;

  /// 随这些作品删除的 `media_open_history` 行数。
  final int historyEntries;

  /// 删除作品后清理掉的无归属阅读状态行数：Reading progress
  /// （`reader_positions`）与 Chapter 已读 / 章级进度（`manga_chapter_states`）。
  final int readingStateRows;
}

/// 进度通知：当前阶段与 0..1 的粗略进度。
class MangaDatabaseClearProgress {
  const MangaDatabaseClearProgress({
    required this.step,
    required this.fraction,
  });

  final MangaDatabaseClearStep step;
  final double fraction;
}

/// 设置 →「存储与下载」→「数据存储位置」的「清理数据库」数据层（ticket 13）。
///
/// 对齐 Mihon 的 Clear database：
/// - 按 Source 列出 membership=false 的漫画行及其数量，供多选；
/// - 默认保留有已读章节 / 阅读进度的非书架作品（[measureSources] 的
///   [MangaDatabaseClearSource.readWorks]）；
/// - 只删除所选 Source 的 membership=false 行及其章节状态 / 阅读位置 / 覆盖 /
///   下载任务 / 章节容器映射（复用 [FushiDatabase.deleteEpubBook] 的记录级级联；
///   它不删除任何磁盘文件）；
/// - 只删除**被清理作品**对应的 History；书架作品与其 History 原样保留；
/// - 最后清理无归属的 `reader_positions` / `manga_chapter_states` 孤儿行。
///
/// 永不触碰磁盘文件：Download library 文件、Local source 文件都保留；设置、源、
/// 扩展、搜索历史与 Tracking 数据同样保留。
///
/// Library 成员判据与书架同源：`epub_books.in_library`（见
/// `library_membership.dart`）。`format` 只描述书身份，不再表示书架归属。
class MangaDatabaseClearService {
  const MangaDatabaseClearService({
    required this.database,
    @visibleForTesting this.debugBeforeStep,
  });

  final FushiDatabase database;

  /// 测试缝：每个阶段删除前调用；抛错用于验证整个删除在单事务内回滚。
  @visibleForTesting
  final Future<void> Function(MangaDatabaseClearStep step)? debugBeforeStep;

  /// 列出有非书架漫画的 Source 及计数。读取后用户可能取消，所以 [run] 不依赖它。
  Future<List<MangaDatabaseClearSource>> measureSources() async {
    final List<_ClearWork> works = await _loadNonLibraryWorks();
    if (works.isEmpty) return const <MangaDatabaseClearSource>[];

    final Set<String> readUids = await _readBearingUids(
      works.map((_ClearWork work) => work.uid),
    );
    final Set<String> historyKeys = await _existingHistoryKeys();
    final _OnlineSourceNameResolver names = _OnlineSourceNameResolver(
      await database.getMangaOnlineSources(mediaKind: 'manga'),
    );

    final Map<String, _SourceBuilder> builders = <String, _SourceBuilder>{};
    for (final _ClearWork work in works) {
      final _SourceRef source = _sourceRefFor(work, names);
      final _SourceBuilder builder = builders.putIfAbsent(
        source.key,
        () => _SourceBuilder(source),
      );
      builder.noteSource(source);
      builder.nonLibraryWorks++;
      final bool read = readUids.contains(work.uid);
      if (read) builder.readWorks++;
      for (final MangaHistoryIdentity identity in work.historyIdentities) {
        if (!historyKeys.contains(identity.key)) continue;
        if (builder.matchedHistoryKeys.add(identity.key)) {
          builder.historyEntries++;
        }
        if (read && builder.matchedReadHistoryKeys.add(identity.key)) {
          builder.readHistoryEntries++;
        }
      }
    }

    final List<MangaDatabaseClearSource> sources =
        <MangaDatabaseClearSource>[
          for (final _SourceBuilder builder in builders.values) builder.build(),
        ]..sort(
          (MangaDatabaseClearSource a, MangaDatabaseClearSource b) =>
              a.key.compareTo(b.key),
        );
    return sources;
  }

  /// 在一个事务里删除所选 Source 的非书架作品；任一阶段失败则全部回滚。
  ///
  /// [sourceKeys] 来自 [measureSources] 的 [MangaDatabaseClearSource.key]；
  /// [keepRead] 为 true（默认）时保留有已读章节或阅读进度的作品。
  Future<MangaDatabaseClearCounts> run({
    Set<String> sourceKeys = const <String>{},
    bool keepRead = true,
    void Function(MangaDatabaseClearProgress progress)? onProgress,
  }) async {
    return database.transaction(() async {
      final List<_ClearWork> works = await _loadNonLibraryWorks();
      final Set<String> readUids = keepRead
          ? await _readBearingUids(works.map((_ClearWork work) => work.uid))
          : const <String>{};
      final _OnlineSourceNameResolver names = _OnlineSourceNameResolver(
        await database.getMangaOnlineSources(mediaKind: 'manga'),
      );

      final List<_ClearWork> removed = <_ClearWork>[];
      final Set<String> historyKeysToDelete = <String>{};
      for (final _ClearWork work in works) {
        final _SourceRef source = _sourceRefFor(work, names);
        if (!sourceKeys.contains(source.key)) continue;
        if (keepRead && readUids.contains(work.uid)) continue;
        removed.add(work);
        historyKeysToDelete.addAll(
          work.historyIdentities.map(
            (MangaHistoryIdentity identity) => identity.key,
          ),
        );
      }

      if (removed.isEmpty) {
        return const MangaDatabaseClearCounts(
          works: 0,
          historyEntries: 0,
          readingStateRows: 0,
        );
      }

      onProgress?.call(
        const MangaDatabaseClearProgress(
          step: MangaDatabaseClearStep.works,
          fraction: 0.1,
        ),
      );
      await debugBeforeStep?.call(MangaDatabaseClearStep.works);
      int worksDeleted = 0;
      for (final _ClearWork work in removed) {
        worksDeleted += await database.deleteEpubBook(work.bookKey);
      }

      onProgress?.call(
        const MangaDatabaseClearProgress(
          step: MangaDatabaseClearStep.history,
          fraction: 0.55,
        ),
      );
      await debugBeforeStep?.call(MangaDatabaseClearStep.history);
      int historyDeleted = 0;
      for (final String key in historyKeysToDelete) {
        final int separator = key.indexOf('\u0000');
        final String mediaSource = key.substring(0, separator);
        final String mediaId = key.substring(separator + 1);
        historyDeleted += await database.deleteMediaOpenHistory(
          mediaSource,
          mediaId,
        );
      }

      onProgress?.call(
        const MangaDatabaseClearProgress(
          step: MangaDatabaseClearStep.readingState,
          fraction: 0.85,
        ),
      );
      await debugBeforeStep?.call(MangaDatabaseClearStep.readingState);
      final int readingStateRows = await _cleanOrphanReadingState();

      return MangaDatabaseClearCounts(
        works: worksDeleted,
        historyEntries: historyDeleted,
        readingStateRows: readingStateRows,
      );
    });
  }

  /// 所有 membership=false 的漫画行。只取身份列，避免把每部作品的章节 JSON
  /// 整库拉一遍。
  Future<List<_ClearWork>> _loadNonLibraryWorks() async {
    final $EpubBooksTable table = database.epubBooks;
    final List<TypedResult> rows =
        await (database.selectOnly(table)
              ..addColumns(<Expression<Object>>[
                table.bookKey,
                table.uid,
                table.format,
                table.sourceMetadata,
              ])
              ..where(
                table.inLibrary.equals(false) &
                    table.format.equals(BookFormat.manga.dbValue),
              ))
            .get();
    return <_ClearWork>[
      for (final TypedResult row in rows)
        _clearWorkFor(
          bookKey: row.read(table.bookKey)!,
          uid: row.read(table.uid) ?? '',
          sourceMetadata: row.read(table.sourceMetadata),
          format: row.read(table.format) ?? BookFormat.manga.dbValue,
        ),
    ];
  }

  _ClearWork _clearWorkFor({
    required String bookKey,
    required String uid,
    required String? sourceMetadata,
    required String format,
  }) {
    final MangaHistoryIdentity legacy = mangaHistoryLegacyReaderIdentity(
      bookKey,
    );
    final MangaHistoryIdentity? canonical = mangaHistoryIdentityForMangaRow(
      bookKey: bookKey,
      sourceMetadata: sourceMetadata,
      format: format,
    );
    final Map<String, MangaHistoryIdentity> identities =
        <String, MangaHistoryIdentity>{
          if (canonical != null) canonical.key: canonical,
          legacy.key: legacy,
        };
    return _ClearWork(
      bookKey: bookKey,
      uid: uid,
      sourceMetadata: sourceMetadata,
      historyIdentities: identities.values.toList(growable: false),
    );
  }

  /// 「有阅读记录」：任一章节已读 / 读了一部分，或书级阅读位置非起始页。
  Future<Set<String>> _readBearingUids(Iterable<String> uids) async {
    final Set<String> wanted = <String>{
      for (final String uid in uids)
        if (uid.isNotEmpty) uid,
    };
    if (wanted.isEmpty) return <String>{};

    final Set<String> result = <String>{};
    final $MangaChapterStatesTable states = database.mangaChapterStates;
    final List<TypedResult> stateRows =
        await (database.selectOnly(states)
              ..addColumns(<Expression<Object>>[
                states.bookUid,
                states.readAt,
                states.lastPage,
                states.lastFraction,
              ])
              ..where(states.bookUid.isIn(wanted)))
            .get();
    for (final TypedResult row in stateRows) {
      if (row.read(states.readAt) != null ||
          (row.read(states.lastPage) ?? 0) > 0 ||
          (row.read(states.lastFraction) ?? 0) > 0) {
        result.add(row.read(states.bookUid)!);
      }
    }

    final $ReaderPositionsTable positions = database.readerPositions;
    final List<TypedResult> positionRows =
        await (database.selectOnly(positions)
              ..addColumns(<Expression<Object>>[
                positions.bookUid,
                positions.sectionIndex,
                positions.normCharOffset,
                positions.charOffset,
              ])
              ..where(positions.bookUid.isIn(wanted)))
            .get();
    for (final TypedResult row in positionRows) {
      if ((row.read(positions.sectionIndex) ?? 0) > 0 ||
          (row.read(positions.normCharOffset) ?? 0) > 0 ||
          (row.read(positions.charOffset) ?? 0) > 0) {
        result.add(row.read(positions.bookUid)!);
      }
    }
    return result;
  }

  /// 现有 History 身份的集合（`mediaSource\u0000mediaId`）。
  Future<Set<String>> _existingHistoryKeys() async {
    final $MediaOpenHistoryTable table = database.mediaOpenHistory;
    final List<TypedResult> rows =
        await (database.selectOnly(table)..addColumns(<Expression<Object>>[
              table.mediaSource,
              table.mediaId,
            ]))
            .get();
    return <String>{
      for (final TypedResult row in rows)
        '${row.read(table.mediaSource)}\u0000${row.read(table.mediaId)}',
    };
  }

  /// 删除没有任何现存作品行归属的阅读状态（`reader_positions` 与
  /// `manga_chapter_states`）。被保留的作品（书架 / 未选 Source / 开关保留的
  /// 已读作品）的状态不动。
  Future<int> _cleanOrphanReadingState() async {
    final $EpubBooksTable books = database.epubBooks;
    final List<TypedResult> rows = await (database.selectOnly(
      books,
    )..addColumns(<Expression<Object>>[books.uid])).get();
    final Set<String> remainingUids = <String>{
      for (final TypedResult row in rows)
        if ((row.read(books.uid) ?? '').isNotEmpty) row.read(books.uid)!,
    };

    final Expression<bool> positionPredicate = remainingUids.isEmpty
        ? const Constant<bool>(true)
        : database.readerPositions.bookUid.isNotIn(remainingUids);
    final int positions = await (database.delete(
      database.readerPositions,
    )..where((_) => positionPredicate)).go();

    final Expression<bool> statePredicate = remainingUids.isEmpty
        ? const Constant<bool>(true)
        : database.mangaChapterStates.bookUid.isNotIn(remainingUids);
    final int states = await (database.delete(
      database.mangaChapterStates,
    )..where((_) => statePredicate)).go();
    return positions + states;
  }

  _SourceRef _sourceRefFor(_ClearWork work, _OnlineSourceNameResolver names) {
    final OnlineMangaLibraryEntry? online = OnlineMangaLibraryEntry.tryParse(
      work.sourceMetadata,
    );
    if (online != null) {
      return _SourceRef(
        key: _onlineSourceKey(online),
        kind: MangaDatabaseClearSourceKind.online,
        name: names.resolve(online) ?? trimmedOrNull(online.sourceName),
        runtime: online.runtime,
        sourceId: online.sourceId,
      );
    }
    if (LocalSourceMetadata.tryParse(work.sourceMetadata) != null) {
      return const _SourceRef(
        key: 'local_source',
        kind: MangaDatabaseClearSourceKind.localSource,
      );
    }
    return const _SourceRef(
      key: 'imported',
      kind: MangaDatabaseClearSourceKind.imported,
    );
  }

  /// 同一 Mihon Source 的占位扩展包与真实扩展包共享数字 sourceId 身份，
  /// 因此按数字 id 分组；非数字 id（互联等）保留完整三元组。
  String _onlineSourceKey(OnlineMangaLibraryEntry entry) {
    final String? normalized = normalizedMangaSourceId(entry.sourceId);
    if (entry.runtime == OnlineMangaRuntimeKind.mihon && normalized != null) {
      return 'online\u0000mihon\u0000$normalized';
    }
    return 'online\u0000${entry.runtime.wireValue}'
        '\u0000${entry.extensionPackage}\u0000${entry.sourceId}';
  }
}

class _ClearWork {
  const _ClearWork({
    required this.bookKey,
    required this.uid,
    required this.sourceMetadata,
    required this.historyIdentities,
  });

  final String bookKey;
  final String uid;
  final String? sourceMetadata;
  final List<MangaHistoryIdentity> historyIdentities;
}

class _SourceRef {
  const _SourceRef({
    required this.key,
    required this.kind,
    this.name,
    this.runtime,
    this.sourceId = '',
  });

  final String key;
  final MangaDatabaseClearSourceKind kind;
  final String? name;
  final OnlineMangaRuntimeKind? runtime;
  final String sourceId;
}

class _SourceBuilder {
  _SourceBuilder(_SourceRef source) : source = source, name = source.name;

  final _SourceRef source;

  /// 同组条目可能一个是占位扩展包（无名称）、一个是真实扩展包（有名称）；
  /// 取第一个能解析到的名称。
  String? name;

  /// 已计入的 History 身份，防止重复作品行共享同一身份时重复计数。
  final Set<String> matchedHistoryKeys = <String>{};
  final Set<String> matchedReadHistoryKeys = <String>{};

  int nonLibraryWorks = 0;
  int readWorks = 0;
  int historyEntries = 0;
  int readHistoryEntries = 0;

  void noteSource(_SourceRef other) {
    final String? otherName = trimmedOrNull(other.name);
    if (name == null && otherName != null) name = otherName;
  }

  MangaDatabaseClearSource build() => MangaDatabaseClearSource(
    key: source.key,
    kind: source.kind,
    name: name,
    runtime: source.runtime,
    sourceId: source.sourceId,
    nonLibraryWorks: nonLibraryWorks,
    readWorks: readWorks,
    historyEntries: historyEntries,
    readHistoryEntries: readHistoryEntries,
  );
}

/// Source 表名称解析：先精确匹配 `(extensionPackage, sourceId)`，再按数字
/// sourceId 在唯一扩展包内回退。同一 sourceId 命中多个包时视为歧义，不猜。
class _OnlineSourceNameResolver {
  _OnlineSourceNameResolver(this.sources);

  final List<MangaOnlineSourceRow> sources;

  String? resolve(OnlineMangaLibraryEntry entry) {
    if (entry.runtime != OnlineMangaRuntimeKind.mihon) return null;
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
}
