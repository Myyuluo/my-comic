import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi_core/fushi_core.dart';

/// 票 03：导入时扩展未安装 → 条目持久化为 `mihon.unavailable` 占位来源；
/// 扩展安装/启用后，Mihon 来源解析按数字 `sourceId` 回退到真实 Source，
/// 刷新、页流、下载、封面与来源名都能用，且不改写条目身份。
void main() {
  const String realPackage = 'eu.kanate.tachiyomi.extension.zh.zaimanhua';
  const String realSourceId = '524579092615598717';
  const String realSourceName = '再漫画';
  const String seriesKey = '/manga/123456';

  late Directory root;
  late FushiDatabase database;
  late MihonManager manager;
  late _SourceRuntime runtime;

  MangaOnlineSourceRow sourceRow({
    String extensionPackage = realPackage,
    String sourceId = realSourceId,
    String name = realSourceName,
    bool enabled = true,
  }) => MangaOnlineSourceRow(
    mediaKind: 'manga',
    extensionPackage: extensionPackage,
    sourceId: sourceId,
    name: name,
    language: 'zh',
    baseUrl: 'https://example.invalid',
    enabled: enabled,
    pinned: false,
    sortOrder: 0,
  );

  Future<void> seedSource(
    MangaOnlineSourceRow row, {
    bool extensionEnabled = true,
  }) async {
    await database.upsertMangaExtension(
      MangaExtensionsCompanion.insert(
        packageName: row.extensionPackage,
        name: '${row.extensionPackage} extension',
        versionCode: 1,
        versionName: '1.0.0',
        libVersion: '1.6',
        language: 'zh',
        apkPath: 'extensions/${row.extensionPackage}.ext',
        apkSha256: 'apk-sha',
        signerSha256: 'signer-sha',
        enabled: Value<bool>(extensionEnabled),
        installedAt: 1,
      ),
    );
    await database.replaceMangaOnlineSources(
      row.extensionPackage,
      <MangaOnlineSourcesCompanion>[
        MangaOnlineSourcesCompanion.insert(
          extensionPackage: row.extensionPackage,
          sourceId: row.sourceId,
          name: row.name,
          language: row.language,
          baseUrl: Value<String>(row.baseUrl),
          enabled: Value<bool>(row.enabled),
        ),
      ],
    );
    // replace 会保留已有源的设置；显式改启用位才能覆盖同一 Source 的旧状态。
    await database.updateMangaOnlineSourceSettings(
      extensionPackage: row.extensionPackage,
      sourceId: row.sourceId,
      enabled: row.enabled,
    );
  }

  OnlineMangaLibraryEntry placeholderEntry({
    String sourceId = realSourceId,
    String key = seriesKey,
    List<OnlineMangaChapter> chapters = const <OnlineMangaChapter>[],
  }) => OnlineMangaLibraryEntry(
    runtime: OnlineMangaRuntimeKind.mihon,
    extensionPackage: kUnavailableMihonExtensionPackage,
    sourceId: sourceId,
    series: OnlineMangaSeries(
      key: key,
      title: 'Fixture series',
      coverUrl: 'https://example.invalid/cover.jpg',
      raw: <String, Object?>{'url': key, 'title': 'Fixture series'},
    ),
    chapters: chapters,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-installed-fallback-');
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    runtime = _SourceRuntime();
    manager = MihonManager(
      database: database,
      rootDirectory: root,
      runtime: runtime,
    );
  });

  tearDown(() async {
    manager.dispose();
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('来源可用性要求扩展与在线源两侧都启用', () async {
    await seedSource(sourceRow());
    await manager.initialise();
    final MihonLibraryAdapter adapter = MihonLibraryAdapter(manager);
    expect(await adapter.isSourceAvailable(placeholderEntry()), isTrue);

    await seedSource(sourceRow(enabled: false));
    expect(
      await adapter.isSourceAvailable(placeholderEntry()),
      isFalse,
      reason: '在线源停用等同于来源不可用',
    );

    await seedSource(sourceRow(), extensionEnabled: false);
    expect(
      await adapter.isSourceAvailable(placeholderEntry()),
      isFalse,
      reason: '扩展停用时即使源行仍为 enabled，来源也不可用',
    );
  });

  test('来源名解析按数字 sourceId 回退到已启用的真实 Source', () async {
    await seedSource(sourceRow());
    await manager.initialise();

    final String? label = await MihonLibraryAdapter(
      manager,
    ).sourceLabel(placeholderEntry());

    expect(label, realSourceName);
  });

  test('刷新、页流与封面走同一回退规则，条目身份不变', () async {
    await seedSource(sourceRow());
    await manager.initialise();
    final MihonLibraryAdapter adapter = MihonLibraryAdapter(manager);
    final OnlineMangaLibraryEntry entry = placeholderEntry(
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: '/chapter/1',
          name: 'Chapter 1',
          raw: <String, Object?>{'url': '/chapter/1', 'name': 'Chapter 1'},
        ),
      ],
    );
    final String identityBefore = entry.encode();

    final OnlineMangaRefreshResult refreshed = await adapter.refresh(entry);
    expect(runtime.lastDetailsSource?.id, realSourceId);
    expect(runtime.lastDetailsSource?.name, realSourceName);
    expect(refreshed.series.key, seriesKey);
    expect(refreshed.chapters.single.key, '/chapter/1');

    final List<OnlineMangaPageRef> pages = await adapter.resolveChapterPages(
      entry: entry,
      chapter: entry.chapters.single,
    );
    expect(runtime.lastPagesSource?.id, realSourceId);
    expect(pages.single, isA<MihonMangaPageRef>());

    final List<int> cover = await adapter.fetchCover(
      entry,
      'https://example.invalid/cover.jpg',
    );
    expect(runtime.lastCoverSource?.id, realSourceId);
    expect(cover, <int>[0xff, 0xd8, 0xff]);

    expect(
      entry.encode(),
      identityBefore,
      reason: '运行时回退不得改写 extensionPackage / sourceId / bookKey 身份',
    );
  });

  test('章节抓取失败：错误仍携带详情阶段拿到的系列与封面 URL', () async {
    await seedSource(sourceRow());
    await manager.initialise();
    runtime.coverUrl = 'https://example.invalid/fresh-cover.jpg';
    runtime.chaptersError = StateError('Cloudflare challenge');

    await expectLater(
      MihonLibraryAdapter(manager).refresh(placeholderEntry()),
      throwsA(
        isA<OnlineMangaUnavailable>()
            .having((OnlineMangaUnavailable e) => e.stage, 'stage', 'chapters')
            .having(
              (OnlineMangaUnavailable e) => e.series?.coverUrl,
              'series.coverUrl',
              'https://example.invalid/fresh-cover.jpg',
            ),
      ),
      reason: '详情已经成功时，章节失败不得让新的封面 URL 一起丢失（票 06）',
    );
  });

  test('刷新把源列表下标写成 sourceOrder（0 = 最新一话）', () async {
    await seedSource(sourceRow());
    await manager.initialise();
    runtime.chapters = const <MihonChapter>[
      MihonChapter(
        url: '/chapter/3',
        name: 'Chapter 3',
        uploadedAt: 3,
        number: 3,
      ),
      MihonChapter(
        url: '/chapter/2',
        name: 'Chapter 2',
        uploadedAt: 2,
        number: 2,
      ),
      MihonChapter(
        url: '/chapter/1',
        name: 'Chapter 1',
        uploadedAt: 1,
        number: 1,
      ),
    ];

    final OnlineMangaRefreshResult refreshed = await MihonLibraryAdapter(
      manager,
    ).refresh(placeholderEntry());

    expect(
      refreshed.chapters.map((OnlineMangaChapter chapter) => chapter.key),
      <String>['/chapter/3', '/chapter/2', '/chapter/1'],
    );
    expect(
      refreshed.chapters.map(
        (OnlineMangaChapter chapter) => chapter.sourceOrder,
      ),
      <int>[0, 1, 2],
      reason: '适配器按列表下标补 sourceOrder，在线源换章方向不变',
    );
  });

  test('精确匹配优先：同数字 sourceId 的另一个扩展不参与竞争', () async {
    await seedSource(
      sourceRow(extensionPackage: 'org.example.exact', name: 'Exact source'),
    );
    await seedSource(
      sourceRow(extensionPackage: 'org.example.other', name: 'Other source'),
    );
    await manager.initialise();

    final OnlineMangaLibraryEntry exact = OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'org.example.exact',
      sourceId: realSourceId,
      series: placeholderEntry().series,
      chapters: const <OnlineMangaChapter>[],
    );

    expect(
      await MihonLibraryAdapter(manager).sourceLabel(exact),
      'Exact source',
    );
  });

  test('数字 sourceId 按数值比较：前导零不影响回退', () async {
    await seedSource(sourceRow());
    await manager.initialise();

    final String? label = await MihonLibraryAdapter(
      manager,
    ).sourceLabel(placeholderEntry(sourceId: '0$realSourceId'));

    expect(label, realSourceName);
  });

  test('同一数字 sourceId 命中多个已启用扩展：歧义，不随意选择', () async {
    await seedSource(
      sourceRow(extensionPackage: 'org.example.one', name: 'Source one'),
    );
    await seedSource(
      sourceRow(extensionPackage: 'org.example.two', name: 'Source two'),
    );
    await manager.initialise();
    final MihonLibraryAdapter adapter = MihonLibraryAdapter(manager);

    expect(await adapter.sourceLabel(placeholderEntry()), isNull);
    await expectLater(
      adapter.refresh(placeholderEntry()),
      throwsA(
        isA<OnlineMangaUnavailable>().having(
          (OnlineMangaUnavailable error) => error.reason,
          'reason',
          OnlineMangaUnavailableReason.sourceDisabled,
        ),
      ),
    );
  });

  test('真正没有对应 sourceId 的已启用来源：仍按来源缺失失败', () async {
    await seedSource(sourceRow(sourceId: '111111111111111111'));
    await manager.initialise();
    final MihonLibraryAdapter adapter = MihonLibraryAdapter(manager);

    expect(await adapter.sourceLabel(placeholderEntry()), isNull);
    await expectLater(
      adapter.refresh(placeholderEntry()),
      throwsA(
        isA<OnlineMangaUnavailable>().having(
          (OnlineMangaUnavailable error) => error.reason,
          'reason',
          OnlineMangaUnavailableReason.sourceDisabled,
        ),
      ),
    );
  });

  test('来源行被停用：不参与回退，仍按来源缺失失败', () async {
    await seedSource(sourceRow(enabled: false));
    await manager.initialise();
    final MihonLibraryAdapter adapter = MihonLibraryAdapter(manager);

    expect(await adapter.sourceLabel(placeholderEntry()), isNull);
    await expectLater(
      adapter.refresh(placeholderEntry()),
      throwsA(
        isA<OnlineMangaUnavailable>().having(
          (OnlineMangaUnavailable error) => error.reason,
          'reason',
          OnlineMangaUnavailableReason.sourceDisabled,
        ),
      ),
    );
  });
}

class _SourceRuntime extends Fake implements MihonRuntime {
  MihonSource? lastDetailsSource;
  MihonSource? lastPagesSource;
  MihonSource? lastCoverSource;

  String coverUrl = 'https://example.invalid/cover.jpg';

  /// 非空 = `getChapters` 抛这个错误（模拟 Cloudflare / 站点抽风）。
  Object? chaptersError;

  List<MihonChapter> chapters = const <MihonChapter>[
    MihonChapter(
      url: '/chapter/1',
      name: 'Chapter 1',
      uploadedAt: 1,
      number: 1,
    ),
  ];

  @override
  Future<MihonManga> getDetails(
    MihonExtensionRef extension,
    MihonSource source,
    MihonManga manga, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    lastDetailsSource = source;
    return MihonManga(
      url: manga.url,
      title: 'Fixture series',
      coverUrl: coverUrl,
    );
  }

  @override
  Future<List<MihonChapter>> getChapters(
    MihonExtensionRef extension,
    MihonSource source,
    MihonManga manga, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    final Object? error = chaptersError;
    if (error != null) {
      // ignore: only_throw_errors — 测试要原样抛回编排好的错误对象。
      throw error;
    }
    return chapters;
  }

  @override
  Future<List<MihonPage>> getPages(
    MihonExtensionRef extension,
    MihonSource source,
    MihonChapter chapter, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    lastPagesSource = source;
    return const <MihonPage>[
      MihonPage(index: 0, url: 'https://example.invalid/page-1.jpg'),
    ];
  }

  @override
  Future<Uint8List> fetchSourceImage(
    MihonExtensionRef extension,
    MihonSource source,
    String url, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    lastCoverSource = source;
    return Uint8List.fromList(<int>[0xff, 0xd8, 0xff]);
  }

  @override
  Future<void> dispose() async {}
}
