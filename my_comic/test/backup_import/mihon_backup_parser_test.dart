import 'package:flutter_test/flutter_test.dart';

import 'package:my_comic/src/backup_import/mihon_backup_parser.dart';

import 'mihon_backup_fixture.dart';

/// Seam: [MihonBackupParser.parseBytes] (bytes in, backup model out).
///
/// Field numbers mirror Mihon v0.21.3
/// `eu.kanade.tachiyomi.data.backup.models.*`; fixtures are synthetic.
void main() {
  test('reads tracking, extension stores and source preferences', () {
    final MihonBackupData data = MihonBackupParser.parseBytes(
      encodeFixtureBackup(
        mangas: const <FixtureManga>[
          FixtureManga(
            source: 123,
            url: '/manga/alpha',
            title: 'Alpha',
            tracking: <FixtureTracking>[
              FixtureTracking(
                syncId: 5,
                mediaId: 4242,
                mediaIdInt: 0,
                title: 'Alpha (Bangumi)',
                lastChapterRead: 12.5,
                totalChapters: 40,
                score: 8,
                status: 1,
                startedReadingDate: 1700000000000,
                finishedReadingDate: 0,
                trackingUrl: 'https://bgm.tv/subject/4242',
                libraryId: 77,
              ),
              FixtureTracking(
                syncId: 2,
                mediaId: 99,
                title: 'Alpha (AniList)',
                lastChapterRead: 10,
              ),
            ],
          ),
        ],
        extensionStores: const <FixtureExtensionStore>[
          FixtureExtensionStore(
            indexUrl: 'https://example.test/index.pb',
            name: 'Example',
            badgeLabel: 'Ex',
            signingKey: 'key-1',
            contactWebsite: 'https://example.test',
            contactDiscord: 'discord-1',
            isLegacy: false,
            extensionListUrl: 'https://example.test/list',
          ),
        ],
        sourcePreferences: const <FixtureSourcePreferences>[
          FixtureSourcePreferences(
            sourceKey: 'source_123',
            prefs: <FixturePreference>[
              FixturePreference(
                key: 'username',
                type: FixturePreferenceType.stringValue,
                value: 'reader',
              ),
              FixturePreference(
                key: 'enabled',
                type: FixturePreferenceType.booleanValue,
                value: true,
              ),
              FixturePreference(
                key: 'retries',
                type: FixturePreferenceType.intValue,
                value: 3,
              ),
              FixturePreference(
                key: 'timeout',
                type: FixturePreferenceType.longValue,
                value: 9000,
              ),
              FixturePreference(
                key: 'rate',
                type: FixturePreferenceType.floatValue,
                value: 1.5,
              ),
              FixturePreference(
                key: 'domains',
                type: FixturePreferenceType.stringSetValue,
                value: <String>['a.test', 'b.test'],
              ),
            ],
          ),
        ],
      ),
    );

    expect(data.mangas, hasLength(1));
    final List<MihonBackupTracking> tracking = data.mangas.single.tracking;
    expect(tracking, hasLength(2));
    expect(tracking.first.syncId, 5);
    expect(tracking.first.mediaId, 4242);
    expect(tracking.first.mediaIdInt, isNull);
    expect(tracking.first.title, 'Alpha (Bangumi)');
    expect(tracking.first.lastChapterRead, 12.5);
    expect(tracking.first.totalChapters, 40);
    expect(tracking.first.score, 8);
    expect(tracking.first.status, 1);
    expect(tracking.first.startedReadingDate, 1700000000000);
    expect(tracking.first.finishedReadingDate, isNull);
    expect(tracking.first.trackingUrl, 'https://bgm.tv/subject/4242');
    expect(tracking.first.libraryId, 77);
    expect(tracking.last.syncId, 2);

    expect(data.extensionStores, hasLength(1));
    final MihonBackupExtensionStore store = data.extensionStores.single;
    expect(store.indexUrl, 'https://example.test/index.pb');
    expect(store.name, 'Example');
    expect(store.badgeLabel, 'Ex');
    expect(store.signingKey, 'key-1');
    expect(store.contactWebsite, 'https://example.test');
    expect(store.contactDiscord, 'discord-1');
    expect(store.isLegacy, isFalse);
    expect(store.extensionListUrl, 'https://example.test/list');

    expect(data.sourcePreferences, hasLength(1));
    final MihonBackupSourcePreferences preferences =
        data.sourcePreferences.single;
    expect(preferences.sourceKey, 'source_123');
    expect(preferences.preferences, hasLength(6));
    final Map<String, MihonBackupPreference> byKey =
        <String, MihonBackupPreference>{
          for (final MihonBackupPreference preference
              in preferences.preferences)
            preference.key: preference,
        };
    expect(byKey['username']!.value.type, MihonBackupPreferenceType.string);
    expect(byKey['username']!.value.value, 'reader');
    expect(byKey['enabled']!.value.type, MihonBackupPreferenceType.boolean);
    expect(byKey['enabled']!.value.value, isTrue);
    expect(byKey['retries']!.value.type, MihonBackupPreferenceType.integer);
    expect(byKey['retries']!.value.value, 3);
    expect(byKey['timeout']!.value.type, MihonBackupPreferenceType.long);
    expect(byKey['timeout']!.value.value, 9000);
    expect(byKey['rate']!.value.type, MihonBackupPreferenceType.float);
    expect(byKey['rate']!.value.value, 1.5);
    expect(byKey['domains']!.value.type, MihonBackupPreferenceType.stringSet);
    expect(byKey['domains']!.value.value, <String>['a.test', 'b.test']);
  });
}
