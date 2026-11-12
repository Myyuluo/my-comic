import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:my_comic/i18n/strings.g.dart';
import 'package:my_comic/src/storage/program_state_fallback_notice.dart';

/// Ticket 03：安装目录不可写 → Program state root 回退到
/// `%LOCALAPPDATA%\MyComic\userdata` 时，启动后必须给用户一个可见提示：
/// 便携状态（Library / 设置 / 扩展）不再随安装目录一起拷贝。
void main() {
  tearDown(debugResetProgramStateFallbackNotice);

  group('decideProgramStateFallbackNotice', () {
    test('未使用回退位置：什么都不做', () {
      expect(
        decideProgramStateFallbackNotice(
          fallbackInUse: false,
          alreadyShown: false,
        ),
        ProgramStateFallbackNoticeDecision.none,
      );
    });

    test('使用回退位置且本进程还没提示过：提示一次', () {
      expect(
        decideProgramStateFallbackNotice(
          fallbackInUse: true,
          alreadyShown: false,
        ),
        ProgramStateFallbackNoticeDecision.show,
      );
    });

    test('使用回退位置但本进程已提示：不重复弹', () {
      expect(
        decideProgramStateFallbackNotice(
          fallbackInUse: true,
          alreadyShown: true,
        ),
        ProgramStateFallbackNoticeDecision.none,
      );
    });
  });

  testWidgets('提示框说明回退路径与便携状态，关闭后本进程不再弹', (WidgetTester tester) async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    debugResetProgramStateFallbackNotice();
    const String fallbackPath = r'C:\Users\me\AppData\Local\MyComic\userdata';

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: TextButton(
                onPressed: () => unawaited(
                  maybeShowProgramStateFallbackNotice(
                    context: context,
                    fallbackInUse: true,
                    fallbackPath: fallbackPath,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('program_state_fallback_notice')),
      findsOneWidget,
    );
    expect(find.text(t.program_state_fallback_notice_title), findsOneWidget);
    final String body = t.program_state_fallback_notice_message(
      path: fallbackPath,
    );
    expect(find.text(body), findsOneWidget);
    expect(body, contains(fallbackPath));
    expect(body.toLowerCase(), contains('userdata'));

    await tester.tap(
      find.byKey(const ValueKey<String>('program_state_fallback_notice_ok')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('program_state_fallback_notice')),
      findsNothing,
    );

    // 同一进程再次进入首页（例如切换界面语言导致整树重建）不重复打扰。
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('program_state_fallback_notice')),
      findsNothing,
    );
  });

  testWidgets('未使用回退位置时不弹提示', (WidgetTester tester) async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    debugResetProgramStateFallbackNotice();

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: TextButton(
                onPressed: () => unawaited(
                  maybeShowProgramStateFallbackNotice(
                    context: context,
                    fallbackInUse: false,
                    fallbackPath: r'C:\fallback',
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('program_state_fallback_notice')),
      findsNothing,
    );
  });

  test('首页启动接线：每进程按 AppPaths 回退标记提示一次', () {
    final String home = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();
    expect(home, contains('maybeShowProgramStateFallbackNotice'));
    expect(home, contains('programStateRootIsFallback'));
    expect(home, contains('appModel.appPaths'));
  });
}
