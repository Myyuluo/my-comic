import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/library_progress_reset.dart';
import 'package:fushi/src/pages/implementations/library_progress_reset_dialog.dart';

// 「重置阅读状态」确认框（ticket 04）：只保留「同时撤销最近一次打开的记录」，
// 破坏性的「同时清除它的全部学习记录」不再出现；默认不勾、取消返回 null。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<List<StudyRecordResetScope?>> pumpLauncher(
    WidgetTester tester, {
    bool showRecordOptions = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1400);
    addTearDown(tester.view.reset);
    final List<StudyRecordResetScope?> results = <StudyRecordResetScope?>[];
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
                  showRecordOptions: showRecordOptions,
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

  testWidgets('默认不勾、只展示保留项 → 确认返回 keep', (WidgetTester tester) async {
    final List<StudyRecordResetScope?> results = await pumpLauncher(tester);
    expect(find.text('Some Book'), findsOneWidget);
    expect(
      find.text(t.library_progress_reset_records_last_session),
      findsOneWidget,
      reason: '「同时撤销最近一次打开的记录」必须保留',
    );
    expect(
      find.text(t.library_progress_reset_records_all),
      findsNothing,
      reason: 'ticket 04：破坏性统计选项不再出现',
    );
    expect(
      find.text(t.library_progress_reset_records_all_desc),
      findsNothing,
      reason: 'ticket 04：破坏性统计选项不再出现',
    );
    await tester.tap(find.text(t.library_progress_reset_confirm));
    await tester.pumpAndSettle();
    expect(results, <StudyRecordResetScope?>[StudyRecordResetScope.keep]);
  });

  testWidgets('只勾「最近一次」→ lastSession', (
    WidgetTester tester,
  ) async {
    final List<StudyRecordResetScope?> results = await pumpLauncher(tester);
    await tester.tap(find.text(t.library_progress_reset_records_last_session));
    await tester.pump();
    await tester.tap(find.text(t.library_progress_reset_confirm));
    await tester.pumpAndSettle();
    expect(results.single, StudyRecordResetScope.lastSession);
  });

  testWidgets('取消 → null（什么都不做）', (WidgetTester tester) async {
    final List<StudyRecordResetScope?> results = await pumpLauncher(tester);
    await tester.tap(find.text(t.library_progress_reset_records_last_session));
    await tester.pump();
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(results, <StudyRecordResetScope?>[null]);
  });

  testWidgets('showRecordOptions=false → 不摆任何勾选，恒 keep', (
    WidgetTester tester,
  ) async {
    final List<StudyRecordResetScope?> results = await pumpLauncher(
      tester,
      showRecordOptions: false,
    );
    expect(
      find.text(t.library_progress_reset_records_last_session),
      findsNothing,
    );
    expect(find.text(t.library_progress_reset_records_all), findsNothing);
    await tester.tap(find.text(t.library_progress_reset_confirm));
    await tester.pumpAndSettle();
    expect(results.single, StudyRecordResetScope.keep);
  });
}
