import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/media/manga/mihon/mihon_installed_sources_section.dart';
import 'package:my_comic/src/media/manga/mihon/mihon_manager.dart';
import 'package:my_comic/src/media/manga/mihon/mihon_runtime.dart';
import 'package:my_comic/utils.dart';
import 'package:my_comic_core/my_comic_core.dart';

/// Ticket 04：图源列表里排在「已置顶」分组之前的内置伪源行。
///
/// 内置行不来自扩展源表，但仍参与图源列表自身的搜索与状态 / 语言筛选；关闭
/// 状态筛选与搜索词都必须能把它筛掉。
void main() {
  late Directory root;
  late MyComicDatabase database;
  late MihonManager manager;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('mycomic-builtin-sources-');
    database = MyComicDatabase.forTesting(NativeDatabase.memory());
    manager = MihonManager(
      database: database,
      rootDirectory: root,
      runtime: _FakeRuntime(),
    );
    await database.upsertMangaExtension(
      MangaExtensionsCompanion.insert(
        packageName: 'eu.kanade.example.source',
        name: 'Example extension',
        versionCode: 1,
        versionName: '1.0',
        libVersion: '14',
        language: 'en',
        apkPath: 'example.apk',
        apkSha256: 'aa',
        signerSha256: 'bb',
        installedAt: 1,
        mediaKind: const Value<String>('manga'),
      ),
    );
    await database.replaceMangaOnlineSources(
      'eu.kanade.example.source',
      <MangaOnlineSourcesCompanion>[
        MangaOnlineSourcesCompanion.insert(
          extensionPackage: 'eu.kanade.example.source',
          sourceId: '1',
          name: 'Pinned source',
          language: 'en',
          sortOrder: const Value<int>(0),
          pinned: const Value<bool>(true),
          mediaKind: const Value<String>('manga'),
        ),
      ],
    );
    await manager.reload();
  });

  tearDown(() async {
    manager.dispose();
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> pumpSection(
    WidgetTester tester, {
    required List<BuiltInSourceListRow> builtIns,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(useMaterial3: true),
        home: Scaffold(
          body: CustomScrollView(
            slivers: <Widget>[
              MihonInstalledSourcesSection(
                manager: manager,
                builtInRows: builtIns,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  BuiltInSourceListRow builtIn({required bool enabled}) =>
      BuiltInSourceListRow(
        child: const Text('Built-in local source'),
        searchTerms: const <String>['Built-in local source'],
        enabled: () => enabled,
      );

  testWidgets('内置行排在「已置顶」分组之上', (WidgetTester tester) async {
    await pumpSection(tester, builtIns: <BuiltInSourceListRow>[builtIn(enabled: true)]);

    expect(find.text('Built-in local source'), findsOneWidget);
    expect(
      find.text(t.online_sources_pinned_header),
      findsOneWidget,
      reason: '扩展源里的置顶源照常单独成组',
    );
    expect(
      tester.getTopLeft(find.text('Built-in local source')).dy,
      lessThan(tester.getTopLeft(find.text(t.online_sources_pinned_header)).dy),
      reason: '内置伪源固定第一位，位于「已置顶」分组之上',
    );
  });

  testWidgets('搜索框按名称过滤内置行（它仍参与图源列表搜索）', (
    WidgetTester tester,
  ) async {
    await pumpSection(tester, builtIns: <BuiltInSourceListRow>[builtIn(enabled: true)]);

    await tester.enterText(
      find.byKey(const ValueKey<String>('mihon_sources_search_field')),
      'local',
    );
    await tester.pump();
    expect(find.text('Built-in local source'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('mihon_sources_search_field')),
      'no-such-source',
    );
    await tester.pump();
    expect(find.text('Built-in local source'), findsNothing);
    expect(find.text(t.no_search_results), findsOneWidget);
  });

  testWidgets('搜索框首字输入后焦点仍在', (WidgetTester tester) async {
    await pumpSection(tester, builtIns: <BuiltInSourceListRow>[builtIn(enabled: true)]);

    final Finder field = find.byKey(
      const ValueKey<String>('mihon_sources_search_field'),
    );
    await tester.showKeyboard(field);
    await tester.pump();
    expect(
      tester.widget<TextField>(field).focusNode?.hasFocus,
      isTrue,
      reason: '前置条件：搜索框已聚焦',
    );

    // 模拟 IME 输入第一个字符，不走 tester.enterText 的重新聚焦路径。
    tester.testTextInput.enterText('l');
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(field).focusNode?.hasFocus,
      isTrue,
      reason: '首字输入后焦点必须保持在搜索框',
    );
  });

  testWidgets('状态筛选「已停用」隐藏启用的内置行', (WidgetTester tester) async {
    await pumpSection(tester, builtIns: <BuiltInSourceListRow>[builtIn(enabled: true)]);

    await tester.tap(
      find.byKey(const ValueKey<String>('online_sources_filter_disabled')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Built-in local source'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('online_sources_filter_enabled')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Built-in local source'), findsOneWidget);
  });
}

class _FakeRuntime extends Fake implements MihonRuntime {
  @override
  Future<void> dispose() async {}
}
