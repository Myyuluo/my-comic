import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/backup_export/mihon_backup_exporter.dart';
import 'package:fushi/src/backup_import/mihon_backup_import_service.dart';
import 'package:fushi/src/backup_import/mihon_backup_parser.dart';

/// Seam: [MihonBackupExporter.exportToFile] writes a synthetic `.tachibk` into
/// a temp directory, and [MihonBackupParser.parseFile] reads it back. The tests
/// assert the backup model (what Mihon would restore), never exporter internals.
void main() {
  late Directory tmp;
  late FushiDatabase db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mycomic-stores-source-');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  Future<MihonBackupData> export({
    bool includeExtensionStores = false,
    bool includeSourceSettings = false,
    bool includeSensitiveSettings = false,
    String name = 'backup',
  }) async {
    final File target = File(p.join(tmp.path, '$name.tachibk'));
    await MihonBackupExporter(database: db).exportToFile(
      target: target,
      options: MihonBackupExportOptions(
        includeLibrary: false,
        includeChapters: false,
        includeAppSettings: false,
        includeExtensionStores: includeExtensionStores,
        includeSourceSettings: includeSourceSettings,
        includeSensitiveSettings: includeSensitiveSettings,
      ),
    );
    return MihonBackupParser.parseFile(target);
  }

  test('exports every extension store with its Mihon fields', () async {
    await db
        .into(db.mangaExtensionStores)
        .insert(
          MangaExtensionStoresCompanion.insert(
            indexUrl: 'https://example.test/index.pb',
            name: 'Example',
            format: 'currentProtobuf',
            badgeLabel: const Value<String>('Ex'),
            signingKey: const Value<String>('key-1'),
            contactJson: Value<String?>(
              jsonEncode(<String, String?>{
                'website': 'https://example.test',
                'discord': 'discord-1',
              }),
            ),
            extensionListUrl: const Value<String?>('https://example.test/list'),
          ),
        );
    await db
        .into(db.mangaExtensionStores)
        .insert(
          MangaExtensionStoresCompanion.insert(
            indexUrl: 'https://legacy.test/index.min.json',
            name: 'Legacy',
            format: 'legacy',
            enabled: const Value<bool>(false),
          ),
        );

    final MihonBackupData data = await export(includeExtensionStores: true);

    final Map<String, MihonBackupExtensionStore> byUrl =
        <String, MihonBackupExtensionStore>{
          for (final MihonBackupExtensionStore store in data.extensionStores)
            store.indexUrl: store,
        };
    expect(byUrl.keys.toSet(), <String>{
      'https://example.test/index.pb',
      'https://legacy.test/index.min.json',
    });

    final MihonBackupExtensionStore example =
        byUrl['https://example.test/index.pb']!;
    expect(example.name, 'Example');
    expect(example.badgeLabel, 'Ex');
    expect(example.signingKey, 'key-1');
    expect(example.contactWebsite, 'https://example.test');
    expect(example.contactDiscord, 'discord-1');
    expect(example.isLegacy, isFalse);
    expect(example.extensionListUrl, 'https://example.test/list');

    final MihonBackupExtensionStore legacy =
        byUrl['https://legacy.test/index.min.json']!;
    expect(legacy.name, 'Legacy');
    expect(legacy.isLegacy, isTrue);
    expect(legacy.signingKey, isEmpty);
    expect(legacy.contactWebsite, isEmpty);
  });

  test('exports manga extension stores only (app is manga-only)', () async {
    await db
        .into(db.mangaExtensionStores)
        .insert(
          MangaExtensionStoresCompanion.insert(
            indexUrl: 'https://manga.test/index.pb',
            name: 'Manga Store',
            format: 'currentProtobuf',
          ),
        );
    // Aniyomi (video) store: Mihon's backup format has no media-kind field, so
    // exporting it would recreate it as a manga store on the other side.
    await db
        .into(db.mangaExtensionStores)
        .insert(
          MangaExtensionStoresCompanion.insert(
            indexUrl: 'https://anime.test/index.pb',
            name: 'Anime Store',
            format: 'currentProtobuf',
            mediaKind: const Value<String>('anime'),
          ),
        );

    final MihonBackupData data = await export(includeExtensionStores: true);

    expect(
      data.extensionStores.map(
        (MihonBackupExtensionStore store) => store.indexUrl,
      ),
      <String>['https://manga.test/index.pb'],
    );
  });

  test('extension stores off writes no extension store entries', () async {
    await db
        .into(db.mangaExtensionStores)
        .insert(
          MangaExtensionStoresCompanion.insert(
            indexUrl: 'https://example.test/index.pb',
            name: 'Example',
            format: 'currentProtobuf',
          ),
        );

    final MihonBackupData data = await export();
    expect(data.extensionStores, isEmpty);
  });

  test('exports source settings grouped as source_<sourceId>', () async {
    await _seedSource(db, sourceId: '123', name: 'Source A');
    // A source with no preference rows must not gain an empty container.
    await _seedSource(db, sourceId: '789', name: 'Source C');
    await _seedPreferences(
      db,
      sourceId: '123',
      values: <String, String>{
        'username': jsonEncode('reader'),
        'enabled': jsonEncode(true),
        'retries': jsonEncode(3),
        'rate': jsonEncode(1.5),
        'domains': jsonEncode(<String>['a.test', 'b.test']),
      },
    );
    // Preferences stored by an import for a missing source live under the
    // placeholder package; they are not a usable source configuration.
    await db.upsertMangaSourcePreference(
      MangaSourcePreferencesCompanion.insert(
        extensionPackage: kUnavailableMihonExtensionPackage,
        sourceId: '456',
        preferenceKey: 'api_key',
        preferenceType: 'text',
        valueJson: jsonEncode('secret'),
        updatedAt: 1,
      ),
    );

    final MihonBackupData data = await export(includeSourceSettings: true);

    final MihonBackupSourcePreferences container =
        data.sourcePreferences.single;
    expect(container.sourceKey, 'source_123');
    final Map<String, MihonBackupPreference> byKey =
        <String, MihonBackupPreference>{
          for (final MihonBackupPreference preference in container.preferences)
            preference.key: preference,
        };
    expect(byKey.keys.toSet(), <String>{
      'username',
      'enabled',
      'retries',
      'rate',
      'domains',
    });
    expect(byKey['username']!.value.type, MihonBackupPreferenceType.string);
    expect(byKey['username']!.value.value, 'reader');
    expect(byKey['enabled']!.value.type, MihonBackupPreferenceType.boolean);
    expect(byKey['enabled']!.value.value, isTrue);
    expect(byKey['retries']!.value.type, MihonBackupPreferenceType.integer);
    expect(byKey['retries']!.value.value, 3);
    expect(byKey['rate']!.value.type, MihonBackupPreferenceType.float);
    expect(byKey['rate']!.value.value, closeTo(1.5, 1e-6));
    expect(byKey['domains']!.value.type, MihonBackupPreferenceType.stringSet);
    expect(byKey['domains']!.value.value, <String>['a.test', 'b.test']);
  });

  test('source settings off writes no source preference entries', () async {
    await _seedSource(db, sourceId: '123', name: 'Source A');
    await _seedPreferences(
      db,
      sourceId: '123',
      values: <String, String>{'username': jsonEncode('reader')},
    );

    final MihonBackupData data = await export();
    expect(data.sourcePreferences, isEmpty);
  });

  test(
    'excludes source credentials unless sensitive settings are included',
    () async {
      await _seedSource(db, sourceId: '123', name: 'Source A');
      await _seedPreferences(
        db,
        sourceId: '123',
        values: <String, String>{
          'username': jsonEncode('reader'),
          'password': jsonEncode('hunter2'),
          'api_key': jsonEncode('api-key-value'),
          'auth_token': jsonEncode('token-value'),
          'private_key': jsonEncode('pem-value'),
        },
      );

      final MihonBackupData safe = await export(
        includeSourceSettings: true,
        name: 'safe',
      );
      expect(
        safe.sourcePreferences.single.preferences.map(
          (MihonBackupPreference preference) => preference.key,
        ),
        <String>['username'],
        reason: 'credentials stay out unless the user opts in',
      );

      final MihonBackupData full = await export(
        includeSourceSettings: true,
        includeSensitiveSettings: true,
        name: 'full',
      );
      expect(
        full.sourcePreferences.single.preferences
            .map((MihonBackupPreference preference) => preference.key)
            .toSet(),
        <String>{
          'username',
          'password',
          'api_key',
          'auth_token',
          'private_key',
        },
        reason: 'sensitive settings include the credentials when checked',
      );
    },
  );
}

Future<void> _seedSource(
  FushiDatabase db, {
  required String sourceId,
  required String name,
}) async {
  await db
      .into(db.mangaOnlineSources)
      .insert(
        MangaOnlineSourcesCompanion.insert(
          extensionPackage: 'com.example.ext',
          sourceId: sourceId,
          name: name,
          language: 'en',
        ),
      );
}

Future<void> _seedPreferences(
  FushiDatabase db, {
  required String sourceId,
  required Map<String, String> values,
  String extensionPackage = 'com.example.ext',
}) async {
  for (final MapEntry<String, String> entry in values.entries) {
    await db.upsertMangaSourcePreference(
      MangaSourcePreferencesCompanion.insert(
        extensionPackage: extensionPackage,
        sourceId: sourceId,
        preferenceKey: entry.key,
        preferenceType: 'text',
        valueJson: entry.value,
        updatedAt: 1,
      ),
    );
  }
}
