import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_browse_page.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:material_ui/material_ui.dart';

/// Ticket 01：互联浏览页搜索框在首字输入后保持焦点；IME 组字期间不把
/// composing text 当成最终查询（与共享 `FushiSearchBar` 的组字门同一口径）。
class _FakeBackend extends Fake implements InterconnectSyncBackend {
  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async => <RemoteBookInfo>[
    const RemoteBookInfo(
      title: 'Alpha',
      bookKey: 'alpha',
      hasContent: false,
      format: 'manga',
      hasMangaContent: true,
    ),
    const RemoteBookInfo(
      title: 'Beta',
      bookKey: 'beta',
      hasContent: false,
      format: 'manga',
      hasMangaContent: true,
    ),
  ];
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Widget harness() => ProviderScope(
    child: TranslationProvider(
      child: MaterialApp(
        home: InterconnectMangaBrowsePage(backend: _FakeBackend()),
      ),
    ),
  );

  Finder field() => find.byKey(
    const ValueKey<String>('interconnect_manga_search'),
  );

  testWidgets('互联浏览搜索框首字输入后焦点仍在', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(field(), findsOneWidget);
    await tester.showKeyboard(field());
    await tester.pump();
    expect(
      tester.widget<TextField>(field()).focusNode?.hasFocus,
      isTrue,
      reason: '前置条件：搜索框已聚焦',
    );

    // 模拟 IME 输入第一个字符，不走 tester.enterText 的重新聚焦路径。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'z',
        composing: TextRange(start: 0, end: 1),
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(field()).focusNode?.hasFocus,
      isTrue,
      reason: '首字输入后焦点必须保持在搜索框',
    );
  });

  testWidgets('IME 组字期间不把 composing text 当成最终查询', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);

    await tester.showKeyboard(field());
    await tester.pump();

    // 组字中：尚未选词的拼音不能触发过滤。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'z',
        composing: TextRange(start: 0, end: 1),
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsOneWidget, reason: '组字中不按 composing text 过滤');
    expect(find.text('Beta'), findsOneWidget, reason: '组字中不按 composing text 过滤');

    // 选词确认（composing 收起）：这时才按最终查询过滤。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'z',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsNothing, reason: '确认后才按最终文本过滤');
    expect(find.text('Beta'), findsNothing, reason: '确认后才按最终文本过滤');
  });
}
