import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/library_progress_reset_dialog.dart';

// 「重置阅读状态」确认框（ticket 05）：统计选择已随统计域移除，只剩确认 / 取消。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<List<bool>> pumpLauncher(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1400);
    addTearDown(tester.view.reset);
    final List<bool> results = <bool>[];
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async => results.add(
                await showLibraryProgressResetDialog(
                  context,
                  title: t.library_progress_reset_action,
                  message: t.library_progress_reset_book_message,
                  itemTitle: 'Some Book',
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return results;
  }

  testWidgets('只展示说明与条目名，不再有统计勾选 → 确认返回 true', (
    WidgetTester tester,
  ) async {
    final List<bool> results = await pumpLauncher(tester);
    expect(find.text('Some Book'), findsOneWidget);
    expect(
      find.text(t.library_progress_reset_records_last_session),
      findsNothing,
      reason: 'ticket 05：阅读统计选项已移除',
    );
    expect(
      find.text(t.library_progress_reset_records_all),
      findsNothing,
      reason: '统计清除选项已移除',
    );
    await tester.tap(find.text(t.library_progress_reset_confirm));
    await tester.pumpAndSettle();
    expect(results, <bool>[true]);
  });

  testWidgets('取消 → false（什么都不做）', (WidgetTester tester) async {
    final List<bool> results = await pumpLauncher(tester);
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(results, <bool>[false]);
  });
}
