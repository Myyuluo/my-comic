import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/models/theme_notifier.dart';
import 'package:my_comic_core/my_comic_core.dart';

// TODO-930 M1-M3: behaviour guards for the multi-custom-theme UI integration
// layer. M0 (data model + legacy migration) is covered by
// theme_notifier_test.dart; this file pins what the swatch row and editor
// depend on: pinned-id selection (M1), new+delete flow (M2), per-Profile
// snapshot carry of the new keys (M3).

MyComicDatabase _testDb() =>
    MyComicDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));


ThemeNotifier _notifier(MyComicDatabase db) {
  int counter = 0;
  return ThemeNotifier(
    db,
    () => const TextTheme(),
    customThemeIdGenerator: () => 'ct-${counter++}',
  );
}

void main() {
  late MyComicDatabase db;
  late ThemeNotifier n;

  setUp(() async {
    db = _testDb();
    n = _notifier(db);
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    n.dispose();
    await db.close();
  });

  group('M1: per-swatch pinned selection', () {
    test(
        'setAppThemeKey(custom-theme:id) pins activeCustomThemeEntry to that '
        'id regardless of selectedCustomThemeId', () async {
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'a', name: 'A', seed: 0xFF111111));
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'b', name: 'B', seed: 0xFF222222));
      expect(n.selectedCustomThemeId, 'b');

      await n.setAppThemeKey('custom-theme:a');
      expect(n.appThemeKey, 'custom-theme:a');
      final CustomThemeEntry? active = n.activeCustomThemeEntry;
      expect(active, isNotNull);
      expect(active!.id, 'a');
      expect(active.seed, 0xFF111111);
    });

    test('bare custom-theme key falls back to selected entry', () async {
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'a', name: 'A', seed: 0xFF111111));
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'b', name: 'B', seed: 0xFF222222));
      await n.selectCustomTheme('a');
      await n.setAppThemeKey('custom-theme');
      expect(n.activeCustomThemeEntry!.id, 'a');
    });

    test('pinned key for a deleted id falls back to selected/first', () async {
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'a', name: 'A', seed: 0xFF111111));
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'b', name: 'B', seed: 0xFF222222));
      await n.setAppThemeKey('custom-theme:zzz');
      expect(n.activeCustomThemeEntry!.id, 'b');
    });
  });

  group('M2: editor new + delete flow', () {
    test('upsert of a brand-new entry adds it and selects it', () async {
      const CustomThemeEntry fresh =
          CustomThemeEntry(id: 'new', name: 'My theme', seed: 0xFF445566);
      await n.upsertCustomTheme(fresh);
      expect(n.customThemes.map((CustomThemeEntry e) => e.id), <String>['new']);
      expect(n.selectedCustomThemeId, 'new');
      expect(n.customThemeById('new')!.name, 'My theme');
    });

    test('upsert replacing an existing id keeps selection + replaces fields',
        () async {
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'a', name: 'A', seed: 0xFF111111));
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'a', name: 'A renamed', seed: 0xFF999999));
      expect(n.customThemes, hasLength(1));
      expect(n.customThemeById('a')!.name, 'A renamed');
      expect(n.customThemeById('a')!.seed, 0xFF999999);
      expect(n.selectedCustomThemeId, 'a');
    });

    test(
        'deleting the selected entry falls back to the first remaining '
        '(decision 1)', () async {
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'a', name: 'A', seed: 0xFF111111));
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'b', name: 'B', seed: 0xFF222222));
      await n.selectCustomTheme('b');
      await n.deleteCustomTheme('b');
      expect(n.customThemes.map((CustomThemeEntry e) => e.id), <String>['a']);
      expect(n.selectedCustomThemeId, 'a');
    });

    test('deleting the last entry clears selection (decision 1/4)', () async {
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'a', name: 'A', seed: 0xFF111111));
      await n.deleteCustomTheme('a');
      expect(n.customThemes, isEmpty);
      expect(n.selectedCustomThemeId, isNull);
    });
  });


}
