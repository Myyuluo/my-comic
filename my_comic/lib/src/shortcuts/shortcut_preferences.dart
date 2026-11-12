import 'package:material_ui/material_ui.dart';
import 'package:my_comic/src/media/sources/reader_my_comic_source.dart';
import 'package:my_comic/src/shortcuts/shortcut_registry.dart';

const String _prefKey = 'shortcut_bindings_json';

Future<void> loadShortcutRegistry(
  MyComicShortcutRegistry registry,
  ReaderMyComicSource source,
  TargetPlatform platform,
) async {
  final String? json = source.getPreference<String?>(
    key: _prefKey,
    defaultValue: null,
  );
  // Both branches reset to platform defaults first and notify listeners, so a
  // reload (e.g. on profile switch) fully swaps bindings and refreshes any open
  // settings UI.
  if (json != null) {
    registry.loadFromJsonString(json, platform);
  } else {
    registry.resetToDefaults(platform);
  }
}

Future<void> saveShortcutRegistry(
  MyComicShortcutRegistry registry,
  ReaderMyComicSource source,
) async {
  await source.setPreference<String>(
    key: _prefKey,
    value: registry.toJsonString(),
  );
}
