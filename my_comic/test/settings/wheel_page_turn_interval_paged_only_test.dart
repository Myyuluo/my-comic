import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/media.dart';
import 'package:my_comic/models.dart';
import 'package:my_comic/src/reader/reader_settings.dart';
import 'package:my_comic/src/settings/settings_context.dart';
import 'package:my_comic/src/settings/settings_destination.dart';
import 'package:my_comic/src/settings/settings_schema.dart';
import 'package:my_comic_core/my_comic_core.dart';

import '../helpers/test_platform_services.dart';

/// 滚动（连续）模式的鼠标滚轮是无极滚动（`kContinuousWheelScrollJs`），不翻页，
/// 「滚轮翻页间隔」在那里没有可调的东西 → 隐藏；分页与 VN 的滚轮仍按它限速 → 显示。
void main() {
  late MyComicDatabase db;
  late ReaderSettings readerSettings;

  setUp(() async {
    db = MyComicDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
    readerSettings = ReaderSettings(db);
    await readerSettings.refreshFromDb();
    ReaderMyComicSource.readerSettings = readerSettings;
  });

  tearDown(() async {
    ReaderMyComicSource.readerSettings = null;
    await db.close();
  });

  testWidgets('wheel interval: hidden in continuous, shown in paginated / vn', (
    WidgetTester tester,
  ) async {
    late SettingsContext settingsContext;
    late SettingsSliderItem item;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              settingsContext = SettingsContext(
                context: context,
                appModel: AppModel(testPlatformServices()),
                ref: ref,
                readerSource: ReaderMyComicSource.instance,
                refresh: () {},
              );
              item = buildSettingsSchema(settingsContext)
                  .expand((SettingsDestination d) => d.sections)
                  .expand((SettingsSection s) => s.items)
                  .whereType<SettingsSliderItem>()
                  .firstWhere(
                    (SettingsSliderItem i) =>
                        i.id == 'reading_controls.wheel_page_turn_interval',
                  );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    await readerSettings.setViewMode('paginated');
    expect(item.isVisible(settingsContext), isTrue);

    await readerSettings.setViewMode('continuous');
    expect(
      item.isVisible(settingsContext),
      isFalse,
      reason: '滚动模式滚轮是无极滚动，没有「翻页间隔」',
    );

    await readerSettings.setViewMode('vn');
    expect(item.isVisible(settingsContext), isTrue, reason: 'VN 的滚轮走分页同一条限速通道');
  });
}
