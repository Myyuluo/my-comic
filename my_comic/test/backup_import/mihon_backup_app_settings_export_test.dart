import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic_core/my_comic_core.dart';
import 'package:path/path.dart' as p;

import 'package:my_comic/src/backup_export/mihon_backup_exporter.dart';
import 'package:my_comic/src/backup_import/mihon_backup_parser.dart';

/// Seam: [MihonBackupExporter.exportToFile] writes a synthetic `.tachibk` into
/// a temp directory, and [MihonBackupParser.parseFile] reads it back. The test
/// asserts the backup model, not the exporter's internals, so a different
/// reader implementation would still prove the same user-visible data.
void main() {
  late Directory tmp;
  late MyComicDatabase db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mycomic-app-prefs-export-');
    db = MyComicDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  Future<MihonBackupData> exportPreferences({
    required bool includeAppSettings,
    required bool includeSensitiveSettings,
    String name = 'backup',
  }) async {
    final File target = File(p.join(tmp.path, '$name.tachibk'));
    await MihonBackupExporter(database: db).exportToFile(
      target: target,
      options: MihonBackupExportOptions(
        includeLibrary: false,
        includeChapters: false,
        includeAppSettings: includeAppSettings,
        includeSensitiveSettings: includeSensitiveSettings,
      ),
    );
    return MihonBackupParser.parseFile(target);
  }

  test('exports app preferences with MyComic keys and standard value types', () async {
    await db.setPrefs(<String, String>{
      'shelf_sort_mode': PrefCodec.encode('title'),
      'auto_search': PrefCodec.encode(false),
      'popup_dictionary_columns': PrefCodec.encode(3),
      // Negative int preferences (e.g. "no preset") must survive as int32.
      'video_media_server_quality_preset': PrefCodec.encode(-1),
      // Anki deck ids are epoch milliseconds, i.e. beyond int32.
      'srs_mining_deck_id': PrefCodec.encode(1700000000123),
      'floating_lyric_font_size': PrefCodec.encode(20.5),
      'audio_sources': PrefCodec.encode(<String>[
        'https://a.test',
        'https://b.test',
      ]),
    });

    final MihonBackupData data = await exportPreferences(
      includeAppSettings: true,
      includeSensitiveSettings: false,
    );
    final Map<String, MihonBackupPreferenceValue> byKey =
        <String, MihonBackupPreferenceValue>{
          for (final MihonBackupPreference preference in data.preferences)
            preference.key: preference.value,
        };

    // No Mihon key-name mapping: the rows keep MyComic's own keys.
    expect(byKey.keys.toSet(), <String>{
      'shelf_sort_mode',
      'auto_search',
      'popup_dictionary_columns',
      'video_media_server_quality_preset',
      'srs_mining_deck_id',
      'floating_lyric_font_size',
      'audio_sources',
    });

    expect(byKey['shelf_sort_mode']!.type, MihonBackupPreferenceType.string);
    expect(byKey['shelf_sort_mode']!.value, 'title');
    expect(byKey['auto_search']!.type, MihonBackupPreferenceType.boolean);
    expect(byKey['auto_search']!.value, isFalse);
    expect(
      byKey['popup_dictionary_columns']!.type,
      MihonBackupPreferenceType.integer,
    );
    expect(byKey['popup_dictionary_columns']!.value, 3);
    expect(
      byKey['video_media_server_quality_preset']!.type,
      MihonBackupPreferenceType.integer,
    );
    expect(byKey['video_media_server_quality_preset']!.value, -1);
    expect(byKey['srs_mining_deck_id']!.type, MihonBackupPreferenceType.long);
    expect(byKey['srs_mining_deck_id']!.value, 1700000000123);
    expect(
      byKey['floating_lyric_font_size']!.type,
      MihonBackupPreferenceType.float,
    );
    expect(
      byKey['floating_lyric_font_size']!.value,
      closeTo(20.5, 1e-6),
    );
    expect(byKey['audio_sources']!.type, MihonBackupPreferenceType.stringSet);
    expect(byKey['audio_sources']!.value, <String>[
      'https://a.test',
      'https://b.test',
    ]);
  });

  test('excludes credentials unless sensitive settings are included', () async {
    await db.setPrefs(<String, String>{
      'shelf_sort_mode': PrefCodec.encode('title'),
      'yomitan_api_key': PrefCodec.encode('api-key-value'),
      'media_source_secret_42': PrefCodec.encode('base64-secret'),
      'qb_connection_config': PrefCodec.encode('{"password":"pw"}'),
      // Device-local keys never leave the device, not even when credentials
      // are explicitly included.
      'sync_device_id': PrefCodec.encode('device-1'),
      'sync_ftp_password': PrefCodec.encode('ftp-password'),
      'ai_providers': PrefCodec.encode('[{"apiKeyB64":"abc"}]'),
    });

    final MihonBackupData safe = await exportPreferences(
      includeAppSettings: true,
      includeSensitiveSettings: false,
      name: 'safe',
    );
    expect(
      safe.preferences.map((MihonBackupPreference p) => p.key),
      <String>['shelf_sort_mode'],
      reason: 'credentials and device-local keys stay out by default',
    );

    final MihonBackupData full = await exportPreferences(
      includeAppSettings: true,
      includeSensitiveSettings: true,
      name: 'full',
    );
    expect(
      full.preferences.map((MihonBackupPreference p) => p.key).toSet(),
      <String>{
        'shelf_sort_mode',
        'yomitan_api_key',
        'media_source_secret_42',
        'qb_connection_config',
      },
      reason: 'sensitive keys are included, device-local keys are still not',
    );
  });

  test('app settings off writes no preferences even with sensitive included', () async {
    await db.setPrefs(<String, String>{
      'shelf_sort_mode': PrefCodec.encode('title'),
      'yomitan_api_key': PrefCodec.encode('api-key-value'),
    });

    final MihonBackupData data = await exportPreferences(
      includeAppSettings: false,
      includeSensitiveSettings: true,
    );
    expect(data.preferences, isEmpty);
  });

  test('values without a standard Mihon representation are skipped', () async {
    await db.setPrefs(<String, String>{
      'shelf_sort_mode': PrefCodec.encode('title'),
      // Explicit null and a JSON list of maps cannot map to any of Mihon's six
      // standard preference value types. Writing an unknown serial name would
      // abort Mihon's restore, so these rows are omitted.
      'explicit_null_pref': PrefCodec.encode(null),
      'audio_source_configs': PrefCodec.encode(<Map<String, Object?>>[
        <String, Object?>{'kind': 'local'},
      ]),
    });

    final MihonBackupData data = await exportPreferences(
      includeAppSettings: true,
      includeSensitiveSettings: false,
    );
    expect(
      data.preferences.map((MihonBackupPreference p) => p.key),
      <String>['shelf_sort_mode'],
    );
  });
}
