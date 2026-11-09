import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/downloads/download_task_browser.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/utils.dart';
import 'package:material_ui/material_ui.dart';

/// Ticket 01：下载任务页的搜索框在首字输入后保持焦点。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  testWidgets('下载任务搜索框首字输入后焦点仍在', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: DownloadTaskBrowser(tasks: const <DownloadTaskEntry>[]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder field = find.byKey(
      const ValueKey<String>('download-task-search'),
    );
    expect(field, findsOneWidget);
    await tester.showKeyboard(field);
    await tester.pump();
    expect(
      tester.widget<TextField>(field).focusNode?.hasFocus,
      isTrue,
      reason: '前置条件：搜索框已聚焦',
    );

    tester.testTextInput.enterText('a');
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(field).focusNode?.hasFocus,
      isTrue,
      reason: '首字输入后焦点必须保持在搜索框',
    );
  });
}
