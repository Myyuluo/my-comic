import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/settings/material_settings_renderer.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_home_page.dart';
import 'package:fushi/src/settings/settings_navigation_groups.dart';
import 'package:fushi/src/settings/settings_schema_widgets.dart';
import 'package:fushi/utils.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart' show readyAppModel;
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// Runs against the real app at the host's actual viewport. Desktop window
/// minimum sizes can prevent compact layout, so this records the exercised
/// branch rather than claiming both branches. Run again on a phone emulator
/// for narrow-layout evidence. No synthetic settings page or coordinate input.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('settings groups, navigation and precise search in real app', (
    WidgetTester tester,
  ) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    await runFushiItest(
      label: 'settings-organization',
      collectedErrors: errors,
      body: () async {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue);
        final AppModel appModel = await readyAppModel(tester);
        final bool originalFocus = appModel.experimentalFocusNavigationEnabled;
        try {
          await enableFocusNavigation(tester);
          UpdateChecker.cancelActiveCheck();
          expect(HomePage.debugSelectTab, isNotNull);
          HomePage.debugSelectTab!(HomeTab.settings);
          await tester.pump(const Duration(seconds: 2));
          final Finder home = find.byType(SettingsHomePage);
          expect(home, findsOneWidget);
          final bool wide = tester.getSize(home).width >= 720;
          final String layout = wide ? 'wide' : 'narrow';
          debugPrint(
            '[settings-organization] exercised=$layout width=${tester.getSize(home).width}; alternate viewport requires a separate device run',
          );
          final BuildContext context = tester.element(home);
          if (!context.mounted) {
            throw StateError('Settings home was unmounted before inspection');
          }
          final String appearanceTitle =
              context.t.settings_destination_appearance_interaction;
          final String scaleTitle = context.t.app_ui_scale;
          final Map<SettingsDestinationId, String> smokeDestinations =
              <SettingsDestinationId, String>{
                SettingsDestinationId.downloads: context.t.nav_downloads,
                SettingsDestinationId.services:
                    context.t.settings_destination_services,
                SettingsDestinationId.cardCreation:
                    context.t.settings_destination_card_creation,
                SettingsDestinationId.video:
                    context.t.settings_destination_video,
              };
          // 设置首页扁平化：不再有「界面 / 内容 / 连接 / 应用」一级分组标题，
          // 所有二级分类在同一个连续分组里（窄屏是分组卡、宽屏是导航列表）。
          final Finder homeGroup = find.byKey(settingsHomeGroupKey);
          expect(homeGroup, findsOneWidget);
          for (final String groupTitle in <String>[
            context.t.settings_group_interface,
            context.t.settings_group_content,
            context.t.settings_group_learning,
            context.t.settings_group_connections,
            context.t.settings_group_data,
            context.t.settings_group_app,
          ]) {
            expect(
              find.descendant(of: homeGroup, matching: find.text(groupTitle)),
              findsNothing,
              reason: '一级分组标题「$groupTitle」必须移除',
            );
          }
          final List<AdaptiveSettingsSection> sections = tester
              .widgetList<AdaptiveSettingsSection>(
                find.descendant(
                  of: home,
                  matching: find.byType(AdaptiveSettingsSection),
                ),
              )
              .where(
                (AdaptiveSettingsSection section) =>
                    section.key == settingsHomeGroupKey,
              )
              .toList(growable: false);
          // 窄屏的首页分组是一张 AdaptiveSettingsSection 卡；宽屏左栏是导航
          // 列表，不再是分组卡。
          expect(sections, wide ? isEmpty : hasLength(1));
          if (!wide) {
            expect(sections.single.title, isNull);
            expect(sections.single.collapsible, isFalse);
          }
          await _capture(tester, 'settings-groups-$layout');

          final FocusDriver driver = FocusDriver(tester);
          final Finder appearance = find
              .ancestor(
                of: find.text(appearanceTitle),
                matching: find.byType(FushiListItem),
              )
              .first;
          expect(await driver.focusWidget(appearance), isTrue);
          await driver.activate();
          await tester.pump(const Duration(milliseconds: 500));
          if (!wide) {
            expect(find.byType(SettingsDetailPage), findsOneWidget);
          }
          expect(
            find.byWidgetPredicate(
              (Widget widget) =>
                  widget is SettingsSchemaItem &&
                  widget.item.id == 'appearance.app_ui_scale',
            ),
            findsOneWidget,
          );
          await _capture(tester, 'settings-appearance-$layout');
          if (!wide) {
            await driver.back();
            await tester.pump(const Duration(milliseconds: 500));
          }
          final Finder search = find
              .descendant(
                of: find.byType(SettingsHomePage),
                matching: find.byType(TextField),
              )
              .first;
          expect(await driver.requestFocusInside(search), isTrue);
          await tester.enterText(search, scaleTitle);
          await tester.pump(const Duration(milliseconds: 500));
          final Finder result = find
              .ancestor(
                of: find.text(scaleTitle),
                matching: find.byType(FushiListItem),
              )
              .first;
          expect(await driver.focusWidget(result), isTrue);
          await driver.activate();
          await tester.pump(const Duration(milliseconds: 600));
          final Finder target = find.byWidgetPredicate(
            (Widget widget) =>
                widget is SettingsSchemaItem &&
                widget.item.id == 'appearance.app_ui_scale',
          );
          expect(target, findsOneWidget);
          final Rect bounds = tester.getRect(target);
          final Size viewport =
              tester.view.physicalSize / tester.view.devicePixelRatio;
          expect(
            bounds.overlaps(Offset.zero & viewport),
            isTrue,
            reason: 'Search must reveal the actual setting inside the viewport',
          );
          await _capture(tester, 'settings-search-target-$layout');
          if (!wide) {
            await driver.back();
            await tester.pump(const Duration(milliseconds: 500));
          }
          for (final MapEntry<SettingsDestinationId, String> destination
              in smokeDestinations.entries) {
            final Finder navigationRow = _destinationRow(destination.value);
            expect(
              await driver.focusWidget(navigationRow, maxSteps: 200),
              isTrue,
              reason:
                  '${destination.key.name} must be reachable through the real settings navigation',
            );
            await driver.activate();
            await tester.pump(const Duration(milliseconds: 600));
            if (wide) {
              expect(
                find.byKey(ValueKey<SettingsDestinationId>(destination.key)),
                findsOneWidget,
              );
            } else {
              expect(
                tester
                    .widget<SettingsDetailPage>(find.byType(SettingsDetailPage))
                    .destination
                    ?.id,
                destination.key,
              );
            }
            await _capture(tester, 'settings-${destination.key.name}-$layout');
            // Explicitly leave every body page, including the last one, so
            // controller/listener disposal participates in this smoke test.
            if (wide) {
              expect(
                await driver.focusWidget(
                  _destinationRow(appearanceTitle),
                  maxSteps: 200,
                ),
                isTrue,
              );
              await driver.activate();
              await tester.pump(const Duration(milliseconds: 500));
              expect(
                find.byKey(
                  const ValueKey<SettingsDestinationId>(
                    SettingsDestinationId.appearance,
                  ),
                ),
                findsOneWidget,
              );
              expect(
                find.byKey(ValueKey<SettingsDestinationId>(destination.key)),
                findsNothing,
              );
            } else {
              await driver.back();
              await tester.pump(const Duration(milliseconds: 500));
              expect(find.byType(SettingsDetailPage), findsNothing);
              expect(find.byType(SettingsHomePage), findsOneWidget);
            }
          }
        } finally {
          await appModel.setExperimentalFocusNavigationEnabled(originalFocus);
        }
      },
    );
  });
}

Future<void> _capture(WidgetTester tester, String name) async {
  final ObserveShot shot = await captureFlutterFrame(tester, name);
  expect(shot.saved, isTrue, reason: 'Screenshot evidence must be saved');
  expect(
    shot.nonBlank,
    isTrue,
    reason: 'Settings screenshot must contain rendered content',
  );
  debugPrint('[settings-organization] screenshot=${shot.path}');
}

Finder _destinationRow(String title) {
  // 全部二级分类都在同一个连续分组里：窄屏是分组卡里的 FushiListItem，
  // 宽屏是导航列表里的 Md3SettingsNavRow。
  final Finder group = find.byKey(settingsHomeGroupKey);
  return find.ancestor(
    of: find.descendant(of: group, matching: find.text(title)),
    matching: find.byWidgetPredicate(
      (Widget widget) =>
          widget is FushiListItem || widget is Md3SettingsNavRow,
    ),
  );
}
