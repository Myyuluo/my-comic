import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:my_comic/src/backup_export/mihon_backup_writer.dart';
import 'package:my_comic/src/backup_import/mihon_backup_parser.dart';

/// Seam: the existing Mihon backup parser. The exporter's writer is verified by
/// feeding its bytes back through [MihonBackupParser] — no real `.tachibk`
/// files are committed, and field numbers are asserted against the same model
/// the importer reads.
void main() {
  test('writer emits gzip protobuf that the Mihon parser reads back', () {
    const MihonBackupData source = MihonBackupData(
      mangas: <MihonBackupManga>[
        MihonBackupManga(
          source: 123,
          url: '/manga/alpha',
          title: 'Alpha',
          artist: 'Artist A',
          author: 'Author A',
          description: 'Description A',
          genres: <String>['Action', 'Adventure'],
          status: 2,
          thumbnailUrl: 'https://example.test/alpha.jpg',
          dateAdded: 1700000000000,
          favorite: true,
          chapters: <MihonBackupChapter>[
            MihonBackupChapter(
              url: '/chapter/a1',
              name: 'Chapter 1',
              scanlator: 'Scan A',
              read: true,
              bookmark: true,
              lastPageRead: 7,
              dateFetch: 1700000000100,
              dateUpload: 1690000000100,
              chapterNumber: 1.5,
              sourceOrder: 3,
            ),
            MihonBackupChapter(
              url: '/chapter/a2',
              name: 'Chapter 2',
              scanlator: null,
              read: false,
              bookmark: false,
              lastPageRead: 0,
              dateFetch: 0,
              dateUpload: 0,
              chapterNumber: 0,
              sourceOrder: 4,
            ),
          ],
          categoryOrders: <int>[0, 2],
          history: <MihonBackupHistory>[
            MihonBackupHistory(
              url: '/chapter/a1',
              lastRead: 1700000099000,
              readDuration: 5000,
            ),
          ],
          tracking: <MihonBackupTracking>[
            MihonBackupTracking(
              syncId: 5,
              libraryId: 42,
              mediaIdInt: null,
              trackingUrl: 'https://bgm.tv/subject/42',
              title: 'Alpha',
              lastChapterRead: 12.5,
              totalChapters: 40,
              score: 8,
              status: 1,
              startedReadingDate: 1700000000000,
              finishedReadingDate: null,
              private: false,
              mediaId: 42,
            ),
          ],
        ),
        MihonBackupManga(
          source: 456,
          url: '/manga/beta',
          title: 'Beta',
          artist: null,
          author: null,
          description: null,
          genres: <String>[],
          status: 0,
          thumbnailUrl: null,
          dateAdded: 0,
          favorite: false,
          chapters: <MihonBackupChapter>[],
          categoryOrders: <int>[],
          history: <MihonBackupHistory>[],
          tracking: <MihonBackupTracking>[],
        ),
      ],
      categories: <MihonBackupCategory>[
        MihonBackupCategory(name: 'Action', order: 0, id: 10),
        MihonBackupCategory(name: 'Drama', order: 2, id: 20),
      ],
      sourceNames: <int, String>{123: 'Source A', 456: 'Source B'},
      sourcePreferences: <MihonBackupSourcePreferences>[
        MihonBackupSourcePreferences(
          sourceKey: 'source_123',
          preferences: <MihonBackupPreference>[
            MihonBackupPreference(
              key: 'username',
              value: MihonBackupPreferenceValue(
                type: MihonBackupPreferenceType.string,
                value: 'reader',
              ),
            ),
            MihonBackupPreference(
              key: 'enabled',
              value: MihonBackupPreferenceValue(
                type: MihonBackupPreferenceType.boolean,
                value: true,
              ),
            ),
            MihonBackupPreference(
              key: 'retries',
              value: MihonBackupPreferenceValue(
                type: MihonBackupPreferenceType.integer,
                value: 3,
              ),
            ),
            MihonBackupPreference(
              key: 'timeout',
              value: MihonBackupPreferenceValue(
                type: MihonBackupPreferenceType.long,
                value: 9000000000,
              ),
            ),
            MihonBackupPreference(
              key: 'rate',
              value: MihonBackupPreferenceValue(
                type: MihonBackupPreferenceType.float,
                value: 1.5,
              ),
            ),
            MihonBackupPreference(
              key: 'domains',
              value: MihonBackupPreferenceValue(
                type: MihonBackupPreferenceType.stringSet,
                value: <String>['a.test', 'b.test'],
              ),
            ),
          ],
        ),
      ],
      extensionStores: <MihonBackupExtensionStore>[
        MihonBackupExtensionStore(
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
    );

    final Uint8List bytes = const MihonBackupWriter().encodeGzip(source);
    expect(bytes.take(2).toList(), <int>[0x1f, 0x8b], reason: 'gzip magic');

    final MihonBackupData parsed = MihonBackupParser.parseBytes(bytes);
    expect(parsed.mangas, hasLength(2));

    final MihonBackupManga alpha = parsed.mangas.first;
    expect(alpha.source, 123);
    expect(alpha.url, '/manga/alpha');
    expect(alpha.title, 'Alpha');
    expect(alpha.artist, 'Artist A');
    expect(alpha.author, 'Author A');
    expect(alpha.description, 'Description A');
    expect(alpha.genres, <String>['Action', 'Adventure']);
    expect(alpha.status, 2);
    expect(alpha.thumbnailUrl, 'https://example.test/alpha.jpg');
    expect(alpha.dateAdded, 1700000000000);
    expect(alpha.favorite, isTrue);
    expect(alpha.categoryOrders, <int>[0, 2]);
    expect(alpha.history.single.url, '/chapter/a1');
    expect(alpha.history.single.lastRead, 1700000099000);
    expect(alpha.history.single.readDuration, 5000);
    expect(alpha.tracking.single.syncId, 5);
    expect(alpha.tracking.single.remoteId, 42);
    expect(alpha.tracking.single.lastChapterRead, 12.5);
    expect(alpha.tracking.single.score, 8);

    expect(alpha.chapters, hasLength(2));
    final MihonBackupChapter first = alpha.chapters.first;
    expect(first.url, '/chapter/a1');
    expect(first.name, 'Chapter 1');
    expect(first.scanlator, 'Scan A');
    expect(first.read, isTrue);
    expect(first.bookmark, isTrue);
    expect(first.lastPageRead, 7);
    expect(first.dateFetch, 1700000000100);
    expect(first.dateUpload, 1690000000100);
    expect(first.chapterNumber, closeTo(1.5, 1e-6));
    expect(first.sourceOrder, 3);
    expect(alpha.chapters[1].sourceOrder, 4);

    final MihonBackupManga beta = parsed.mangas[1];
    expect(beta.favorite, isFalse, reason: 'favorite=false must be written');
    expect(beta.url, '/manga/beta');

    expect(
      parsed.categories.map((MihonBackupCategory c) => c.name),
      <String>['Action', 'Drama'],
    );
    expect(parsed.categories[1].order, 2);
    expect(parsed.categories[1].id, 20);
    expect(parsed.sourceNames, <int, String>{123: 'Source A', 456: 'Source B'});

    final MihonBackupSourcePreferences prefs = parsed.sourcePreferences.single;
    expect(prefs.sourceKey, 'source_123');
    final Map<String, MihonBackupPreference> byKey =
        <String, MihonBackupPreference>{
          for (final MihonBackupPreference p in prefs.preferences) p.key: p,
        };
    // Only the six standard kotlinx.serialization value envelopes are valid;
    // an unknown serial name makes Mihon abort the restore.
    expect(byKey['username']!.value.type, MihonBackupPreferenceType.string);
    expect(byKey['username']!.value.value, 'reader');
    expect(byKey['enabled']!.value.type, MihonBackupPreferenceType.boolean);
    expect(byKey['enabled']!.value.value, isTrue);
    expect(byKey['retries']!.value.type, MihonBackupPreferenceType.integer);
    expect(byKey['retries']!.value.value, 3);
    expect(byKey['timeout']!.value.type, MihonBackupPreferenceType.long);
    expect(byKey['timeout']!.value.value, 9000000000);
    expect(byKey['rate']!.value.type, MihonBackupPreferenceType.float);
    expect(byKey['rate']!.value.value, closeTo(1.5, 1e-6));
    expect(byKey['domains']!.value.type, MihonBackupPreferenceType.stringSet);
    expect(byKey['domains']!.value.value, <String>['a.test', 'b.test']);

    final MihonBackupExtensionStore store = parsed.extensionStores.single;
    expect(store.indexUrl, 'https://example.test/index.pb');
    expect(store.name, 'Example');
    expect(store.badgeLabel, 'Ex');
    expect(store.signingKey, 'key-1');
    expect(store.contactWebsite, 'https://example.test');
    expect(store.contactDiscord, 'discord-1');
    expect(store.isLegacy, isFalse);
    expect(store.extensionListUrl, 'https://example.test/list');
  });

  test('writer never emits a non-standard preference value serial name', () {
    expect(
      () => const MihonBackupWriter().encode(
        const MihonBackupData(
          mangas: <MihonBackupManga>[],
          categories: <MihonBackupCategory>[],
          sourceNames: <int, String>{},
          sourcePreferences: <MihonBackupSourcePreferences>[
            MihonBackupSourcePreferences(
              sourceKey: 'source_1',
              preferences: <MihonBackupPreference>[
                MihonBackupPreference(
                  key: 'broken',
                  value: MihonBackupPreferenceValue(
                    type: MihonBackupPreferenceType.unsupported,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      throwsArgumentError,
    );
  });

  test('writer omits default scalars like proto3 and the parser restores them',
      () {
    final Uint8List bytes = const MihonBackupWriter().encode(
      const MihonBackupData(
        mangas: <MihonBackupManga>[
          MihonBackupManga(
            source: 1,
            url: '/manga/zero',
            title: 'Zero',
            artist: null,
            author: null,
            description: null,
            genres: <String>[],
            status: 0,
            thumbnailUrl: null,
            dateAdded: 0,
            favorite: true,
            chapters: <MihonBackupChapter>[
              MihonBackupChapter(
                url: '/c/0',
                name: '',
                scanlator: null,
                read: false,
                bookmark: false,
                lastPageRead: 0,
                dateFetch: 0,
                dateUpload: 0,
                chapterNumber: 0,
                sourceOrder: 0,
              ),
            ],
            categoryOrders: <int>[],
            history: <MihonBackupHistory>[],
            tracking: <MihonBackupTracking>[],
          ),
        ],
        categories: <MihonBackupCategory>[],
        sourceNames: <int, String>{1: 'Source 1'},
      ),
    );

    final MihonBackupData parsed = MihonBackupParser.parseBytes(bytes);
    final MihonBackupManga manga = parsed.mangas.single;
    expect(manga.favorite, isTrue);
    expect(manga.status, 0);
    expect(manga.chapters.single.read, isFalse);
    expect(manga.chapters.single.lastPageRead, 0);
    expect(manga.chapters.single.chapterNumber, 0);
    expect(manga.chapters.single.sourceOrder, 0);
  });

  test('uncompressed writer output is accepted like Mihon protobuf', () {
    final Uint8List bytes = const MihonBackupWriter().encode(
      const MihonBackupData(
        mangas: <MihonBackupManga>[],
        categories: <MihonBackupCategory>[],
        sourceNames: <int, String>{},
      ),
    );
    expect(bytes, isEmpty, reason: 'an empty backup has no top-level fields');
    final MihonBackupData parsed = MihonBackupParser.parseBytes(
      Uint8List.fromList(<int>[0x0a, 0x00]),
    );
    expect(parsed.mangas, hasLength(1));
    expect(parsed.mangas.single.url, isEmpty);
  });

  test('writes Kotlin-required fields even at proto3 defaults', () {
    const MihonBackupData data = MihonBackupData(
      mangas: <MihonBackupManga>[
        MihonBackupManga(
          source: 0,
          url: '',
          title: '',
          artist: null,
          author: null,
          description: null,
          genres: <String>[],
          status: 0,
          thumbnailUrl: null,
          dateAdded: 0,
          favorite: true,
          chapters: <MihonBackupChapter>[
            MihonBackupChapter(
              url: '',
              name: '',
              scanlator: null,
              read: false,
              bookmark: false,
              lastPageRead: 0,
              dateFetch: 0,
              dateUpload: 0,
              chapterNumber: 0,
            ),
          ],
          categoryOrders: <int>[],
          history: <MihonBackupHistory>[
            MihonBackupHistory(url: '', lastRead: 0, readDuration: 0),
          ],
          tracking: <MihonBackupTracking>[
            MihonBackupTracking(
              syncId: 0,
              libraryId: 0,
              mediaIdInt: 0,
              trackingUrl: '',
              title: '',
              lastChapterRead: 0,
              totalChapters: 0,
              score: 0,
              status: 0,
              startedReadingDate: 0,
              finishedReadingDate: 0,
              private: false,
              mediaId: 0,
            ),
          ],
        ),
      ],
      categories: <MihonBackupCategory>[
        MihonBackupCategory(name: '', order: 0, id: 0),
      ],
      sourceNames: <int, String>{0: ''},
      sourcePreferences: <MihonBackupSourcePreferences>[
        MihonBackupSourcePreferences(
          sourceKey: '',
          preferences: <MihonBackupPreference>[
            MihonBackupPreference(
              key: 's',
              value: MihonBackupPreferenceValue(
                type: MihonBackupPreferenceType.string,
                value: '',
              ),
            ),
            MihonBackupPreference(
              key: 'b',
              value: MihonBackupPreferenceValue(
                type: MihonBackupPreferenceType.boolean,
                value: false,
              ),
            ),
            MihonBackupPreference(
              key: 'i',
              value: MihonBackupPreferenceValue(
                type: MihonBackupPreferenceType.integer,
                value: 0,
              ),
            ),
            MihonBackupPreference(
              key: 'l',
              value: MihonBackupPreferenceValue(
                type: MihonBackupPreferenceType.long,
                value: 0,
              ),
            ),
            MihonBackupPreference(
              key: 'f',
              value: MihonBackupPreferenceValue(
                type: MihonBackupPreferenceType.float,
                value: 0.0,
              ),
            ),
          ],
        ),
      ],
      extensionStores: <MihonBackupExtensionStore>[
        MihonBackupExtensionStore(
          indexUrl: '',
          name: '',
          badgeLabel: null,
          signingKey: '',
          contactWebsite: '',
          contactDiscord: null,
          isLegacy: null,
          extensionListUrl: null,
        ),
      ],
    );

    final Map<int, List<Object>> top = _parseProto(
      const MihonBackupWriter().encode(data),
    );

    final Map<int, List<Object>> manga = _parseProto(
      _bytesField(top, 1).first,
    );
    expect(manga.containsKey(1), isTrue, reason: 'BackupManga.source');
    expect(manga.containsKey(2), isTrue, reason: 'BackupManga.url');

    final Map<int, List<Object>> chapter = _parseProto(
      _bytesField(manga, 16).first,
    );
    expect(chapter.containsKey(1), isTrue, reason: 'BackupChapter.url');
    expect(chapter.containsKey(2), isTrue, reason: 'BackupChapter.name');

    final Map<int, List<Object>> history = _parseProto(
      _bytesField(manga, 104).first,
    );
    expect(history.containsKey(1), isTrue, reason: 'BackupHistory.url');
    expect(history.containsKey(2), isTrue, reason: 'BackupHistory.lastRead');

    final Map<int, List<Object>> tracking = _parseProto(
      _bytesField(manga, 18).first,
    );
    expect(tracking.containsKey(1), isTrue, reason: 'BackupTracking.syncId');
    expect(
      tracking.containsKey(2),
      isTrue,
      reason: 'BackupTracking.libraryId',
    );

    final Map<int, List<Object>> category = _parseProto(
      _bytesField(top, 2).first,
    );
    expect(category.containsKey(1), isTrue, reason: 'BackupCategory.name');

    final Map<int, List<Object>> source = _parseProto(
      _bytesField(top, 101).first,
    );
    expect(source.containsKey(2), isTrue, reason: 'BackupSource.sourceId');

    final Map<int, List<Object>> sourcePreferences = _parseProto(
      _bytesField(top, 105).first,
    );
    expect(
      sourcePreferences.containsKey(1),
      isTrue,
      reason: 'BackupSourcePreferences.sourceKey',
    );
    for (final List<int> preferenceBytes
        in _bytesField(sourcePreferences, 2)) {
      final Map<int, List<Object>> preference = _parseProto(
        preferenceBytes,
      );
      expect(preference.containsKey(1), isTrue, reason: 'BackupPreference.key');
      final Map<int, List<Object>> envelope = _parseProto(
        _bytesField(preference, 2).first,
      );
      expect(
        envelope.containsKey(1),
        isTrue,
        reason: 'PreferenceValue serial name',
      );
      final Map<int, List<Object>> payload = _parseProto(
        _bytesField(envelope, 2).first,
      );
      expect(
        payload.containsKey(1),
        isTrue,
        reason: 'PreferenceValue payload must be present even at default',
      );
    }

    final Map<int, List<Object>> store = _parseProto(
      _bytesField(top, 106).first,
    );
    for (final int field in <int>[1, 2, 4, 5]) {
      expect(
        store.containsKey(field),
        isTrue,
        reason: 'BackupExtensionStore.$field is required',
      );
    }
  });
}

/// Minimal generic protobuf reader for the writer's structural assertions.
Map<int, List<Object>> _parseProto(List<int> bytes) {
  final Map<int, List<Object>> fields = <int, List<Object>>{};
  int index = 0;

  int readVarint() {
    int value = 0;
    int shift = 0;
    while (true) {
      final int byte = bytes[index++];
      value |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) return value;
      shift += 7;
    }
  }

  while (index < bytes.length) {
    final int tag = readVarint();
    final int field = tag >> 3;
    final int wire = tag & 7;
    final Object value;
    if (wire == 0) {
      value = readVarint();
    } else if (wire == 1) {
      value = bytes.sublist(index, index + 8);
      index += 8;
    } else if (wire == 2) {
      final int length = readVarint();
      value = bytes.sublist(index, index + length);
      index += length;
    } else if (wire == 5) {
      value = bytes.sublist(index, index + 4);
      index += 4;
    } else {
      throw StateError('Unexpected protobuf wire type $wire');
    }
    fields.putIfAbsent(field, () => <Object>[]).add(value);
  }
  return fields;
}

List<List<int>> _bytesField(Map<int, List<Object>> fields, int field) =>
    fields[field]!.cast<List<int>>();
