import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Synthetic Mihon v0.21.3 `.tachibk` fixture builder.
///
/// The committed tests must never contain a real backup. This file encodes the
/// minimum protobuf surface the importer reads using hand-written wire-format
/// writers, mirroring `eu.kanade.tachiyomi.data.backup.models.*` field numbers.
/// Fixtures are generated at test time into a temp directory.
class FixtureChapter {
  const FixtureChapter({
    required this.url,
    required this.name,
    this.scanlator,
    this.read = false,
    this.bookmark = false,
    this.lastPageRead = 0,
    this.dateFetch = 0,
    this.dateUpload = 0,
    this.chapterNumber = 0,
  });

  final String url;
  final String name;
  final String? scanlator;
  final bool read;
  final bool bookmark;
  final int lastPageRead;
  final int dateFetch;
  final int dateUpload;
  final double chapterNumber;
}

class FixtureHistory {
  const FixtureHistory({
    required this.url,
    required this.lastRead,
    this.readDuration = 0,
  });

  final String url;
  final int lastRead;
  final int readDuration;
}

class FixtureTracking {
  const FixtureTracking({
    required this.syncId,
    required this.mediaId,
    this.mediaIdInt = 0,
    this.trackingUrl = '',
    this.title = '',
    this.lastChapterRead = 0,
    this.totalChapters = 0,
    this.score = 0,
    this.status = 0,
    this.startedReadingDate = 0,
    this.finishedReadingDate = 0,
    this.private = false,
    this.libraryId = 0,
  });

  /// Mihon `Tracker.id`: 1 MAL, 2 AniList, 3 Kitsu, 4 Shikimori, 5 Bangumi…
  final int syncId;
  final int mediaId;
  final int mediaIdInt;
  final String trackingUrl;
  final String title;
  final double lastChapterRead;
  final int totalChapters;
  final double score;
  final int status;
  final int startedReadingDate;
  final int finishedReadingDate;
  final bool private;
  final int libraryId;
}

class FixtureManga {
  const FixtureManga({
    required this.source,
    required this.url,
    required this.title,
    this.artist,
    this.author,
    this.description,
    this.genres = const <String>[],
    this.status = 0,
    this.thumbnailUrl,
    this.dateAdded = 0,
    this.favorite = true,
    this.chapters = const <FixtureChapter>[],
    this.categoryOrders = const <int>[],
    this.history = const <FixtureHistory>[],
    this.tracking = const <FixtureTracking>[],
  });

  final int source;
  final String url;
  final String title;
  final String? artist;
  final String? author;
  final String? description;
  final List<String> genres;
  final int status;
  final String? thumbnailUrl;
  final int dateAdded;
  final bool favorite;
  final List<FixtureChapter> chapters;
  final List<int> categoryOrders;
  final List<FixtureHistory> history;
  final List<FixtureTracking> tracking;
}

class FixtureCategory {
  const FixtureCategory({
    required this.name,
    required this.order,
    required this.id,
  });

  final String name;
  final int order;
  final int id;
}

class FixtureSource {
  const FixtureSource({required this.id, required this.name});

  final int id;
  final String name;
}

/// One `BackupExtensionStore` (top-level field 106).
class FixtureExtensionStore {
  const FixtureExtensionStore({
    required this.indexUrl,
    required this.name,
    this.badgeLabel,
    this.signingKey = '',
    this.contactWebsite = '',
    this.contactDiscord,
    this.isLegacy = false,
    this.extensionListUrl,
  });

  final String indexUrl;
  final String name;
  final String? badgeLabel;
  final String signingKey;
  final String contactWebsite;
  final String? contactDiscord;
  final bool? isLegacy;
  final String? extensionListUrl;
}

/// The value half of a `BackupPreference` (a kotlinx.serialization sealed
/// `PreferenceValue`, encoded as {serialName, payload}).
enum FixturePreferenceType {
  intValue,
  longValue,
  floatValue,
  stringValue,
  booleanValue,
  stringSetValue,
}

class FixturePreference {
  const FixturePreference({
    required this.key,
    required this.type,
    required this.value,
  });

  final String key;
  final FixturePreferenceType type;
  final Object value;
}

class FixtureSourcePreferences {
  const FixtureSourcePreferences({
    required this.sourceKey,
    required this.prefs,
  });

  final String sourceKey;
  final List<FixturePreference> prefs;
}

/// Writes a gzip-compressed Mihon backup file into [directory].
Future<File> writeFixtureBackup(
  Directory directory, {
  required List<FixtureManga> mangas,
  List<FixtureCategory> categories = const <FixtureCategory>[],
  List<FixtureSource> sources = const <FixtureSource>[],
  List<FixtureExtensionStore> extensionStores = const <FixtureExtensionStore>[],
  List<FixtureSourcePreferences> sourcePreferences =
      const <FixtureSourcePreferences>[],
  bool gzip = true,
  String name = 'fixture.tachibk',
}) async {
  final Uint8List payload = encodeFixtureBackup(
    mangas: mangas,
    categories: categories,
    sources: sources,
    extensionStores: extensionStores,
    sourcePreferences: sourcePreferences,
  );
  final List<int> bytes = gzip ? gzipEncode(payload) : payload;
  final File file = File('${directory.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

Uint8List encodeFixtureBackup({
  required List<FixtureManga> mangas,
  List<FixtureCategory> categories = const <FixtureCategory>[],
  List<FixtureSource> sources = const <FixtureSource>[],
  List<FixtureExtensionStore> extensionStores = const <FixtureExtensionStore>[],
  List<FixtureSourcePreferences> sourcePreferences =
      const <FixtureSourcePreferences>[],
}) {
  final _ProtoWriter top = _ProtoWriter();
  for (final FixtureManga manga in mangas) {
    top.bytes(1, _encodeManga(manga));
  }
  for (final FixtureCategory category in categories) {
    top.bytes(2, _encodeCategory(category));
  }
  for (final FixtureSource source in sources) {
    top.bytes(101, _encodeSource(source));
  }
  for (final FixtureSourcePreferences preferences in sourcePreferences) {
    top.bytes(105, _encodeSourcePreferences(preferences));
  }
  for (final FixtureExtensionStore store in extensionStores) {
    top.bytes(106, _encodeExtensionStore(store));
  }
  return top.takeBytes();
}

List<int> gzipEncode(List<int> bytes) => gzip.encode(bytes);

Uint8List _encodeManga(FixtureManga manga) {
  final _ProtoWriter w = _ProtoWriter();
  w.varint(1, manga.source);
  w.string(2, manga.url);
  w.string(3, manga.title);
  if (manga.artist != null) w.string(4, manga.artist!);
  if (manga.author != null) w.string(5, manga.author!);
  if (manga.description != null) w.string(6, manga.description!);
  for (final String genre in manga.genres) {
    w.string(7, genre);
  }
  if (manga.status != 0) w.varint(8, manga.status);
  if (manga.thumbnailUrl != null) w.string(9, manga.thumbnailUrl!);
  if (manga.dateAdded != 0) w.varint(13, manga.dateAdded);
  for (final FixtureChapter chapter in manga.chapters) {
    w.bytes(16, _encodeChapter(chapter));
  }
  if (manga.categoryOrders.isNotEmpty) {
    w.packedInts(17, manga.categoryOrders);
  }
  for (final FixtureHistory history in manga.history) {
    w.bytes(104, _encodeHistory(history));
  }
  for (final FixtureTracking tracking in manga.tracking) {
    w.bytes(18, _encodeTracking(tracking));
  }
  // Proto default for `favorite` is true, so only write the false case.
  if (!manga.favorite) w.varint(100, 0);
  return w.takeBytes();
}

Uint8List _encodeChapter(FixtureChapter chapter) {
  final _ProtoWriter w = _ProtoWriter();
  w.string(1, chapter.url);
  w.string(2, chapter.name);
  if (chapter.scanlator != null) w.string(3, chapter.scanlator!);
  if (chapter.read) w.varint(4, 1);
  if (chapter.bookmark) w.varint(5, 1);
  if (chapter.lastPageRead != 0) w.varint(6, chapter.lastPageRead);
  if (chapter.dateFetch != 0) w.varint(7, chapter.dateFetch);
  if (chapter.dateUpload != 0) w.varint(8, chapter.dateUpload);
  if (chapter.chapterNumber != 0) w.float32(9, chapter.chapterNumber);
  return w.takeBytes();
}

Uint8List _encodeHistory(FixtureHistory history) {
  final _ProtoWriter w = _ProtoWriter();
  w.string(1, history.url);
  w.varint(2, history.lastRead);
  if (history.readDuration != 0) w.varint(3, history.readDuration);
  return w.takeBytes();
}

Uint8List _encodeCategory(FixtureCategory category) {
  final _ProtoWriter w = _ProtoWriter();
  w.string(1, category.name);
  if (category.order != 0) w.varint(2, category.order);
  w.varint(3, category.id);
  return w.takeBytes();
}

Uint8List _encodeSource(FixtureSource source) {
  final _ProtoWriter w = _ProtoWriter();
  w.string(1, source.name);
  w.varint(2, source.id);
  return w.takeBytes();
}

Uint8List _encodeTracking(FixtureTracking tracking) {
  final _ProtoWriter w = _ProtoWriter();
  w.varint(1, tracking.syncId);
  if (tracking.libraryId != 0) w.varint(2, tracking.libraryId);
  if (tracking.mediaIdInt != 0) w.varint(3, tracking.mediaIdInt);
  if (tracking.trackingUrl.isNotEmpty) w.string(4, tracking.trackingUrl);
  w.string(5, tracking.title);
  if (tracking.lastChapterRead != 0) {
    w.float32(6, tracking.lastChapterRead);
  }
  if (tracking.totalChapters != 0) w.varint(7, tracking.totalChapters);
  if (tracking.score != 0) w.float32(8, tracking.score);
  if (tracking.status != 0) w.varint(9, tracking.status);
  if (tracking.startedReadingDate != 0) {
    w.varint(10, tracking.startedReadingDate);
  }
  if (tracking.finishedReadingDate != 0) {
    w.varint(11, tracking.finishedReadingDate);
  }
  if (tracking.private) w.varint(12, 1);
  if (tracking.mediaId != 0) w.varint(100, tracking.mediaId);
  return w.takeBytes();
}

Uint8List _encodeExtensionStore(FixtureExtensionStore store) {
  final _ProtoWriter w = _ProtoWriter();
  w.string(1, store.indexUrl);
  w.string(2, store.name);
  if (store.badgeLabel != null) w.string(3, store.badgeLabel!);
  w.string(4, store.contactWebsite);
  w.string(5, store.signingKey);
  if (store.contactDiscord != null) w.string(6, store.contactDiscord!);
  if (store.isLegacy != null) w.varint(7, store.isLegacy! ? 1 : 0);
  if (store.extensionListUrl != null) {
    w.string(8, store.extensionListUrl!);
  }
  return w.takeBytes();
}

Uint8List _encodeSourcePreferences(FixtureSourcePreferences preferences) {
  final _ProtoWriter w = _ProtoWriter();
  w.string(1, preferences.sourceKey);
  for (final FixturePreference preference in preferences.prefs) {
    w.bytes(2, _encodePreference(preference));
  }
  return w.takeBytes();
}

Uint8List _encodePreference(FixturePreference preference) {
  final _ProtoWriter w = _ProtoWriter();
  w.string(1, preference.key);
  w.bytes(2, _encodePreferenceValue(preference.type, preference.value));
  return w.takeBytes();
}

/// kotlinx.serialization protobuf encodes a sealed class as
/// `{1: fully-qualified serial name, 2: payload message}`; every value class
/// carries its single `value` field at proto field 1.
Uint8List _encodePreferenceValue(FixturePreferenceType type, Object value) {
  final _ProtoWriter payload = _ProtoWriter();
  final String serialName;
  switch (type) {
    case FixturePreferenceType.intValue:
      serialName = 'IntPreferenceValue';
      payload.varint(1, value as int);
    case FixturePreferenceType.longValue:
      serialName = 'LongPreferenceValue';
      payload.varint(1, value as int);
    case FixturePreferenceType.floatValue:
      serialName = 'FloatPreferenceValue';
      payload.float32(1, (value as num).toDouble());
    case FixturePreferenceType.stringValue:
      serialName = 'StringPreferenceValue';
      payload.string(1, value as String);
    case FixturePreferenceType.booleanValue:
      serialName = 'BooleanPreferenceValue';
      payload.varint(1, (value as bool) ? 1 : 0);
    case FixturePreferenceType.stringSetValue:
      serialName = 'StringSetPreferenceValue';
      for (final String item in (value as List<String>)) {
        payload.string(1, item);
      }
  }
  final _ProtoWriter envelope = _ProtoWriter();
  envelope.string(1, 'eu.kanade.tachiyomi.data.backup.models.$serialName');
  envelope.bytes(2, payload.takeBytes());
  return envelope.takeBytes();
}

/// Minimal protobuf wire-format writer (only the field kinds the fixture uses).
class _ProtoWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void varint(int field, int value) {
    _tag(field, 0);
    _varint(value);
  }

  void string(int field, String value) {
    bytes(field, utf8.encode(value));
  }

  void bytes(int field, List<int> value) {
    _tag(field, 2);
    _varint(value.length);
    _builder.add(value);
  }

  void packedInts(int field, List<int> values) {
    final BytesBuilder packed = BytesBuilder(copy: false);
    for (final int value in values) {
      _writeVarint(packed, value);
    }
    bytes(field, packed.takeBytes());
  }

  void float32(int field, double value) {
    _tag(field, 5);
    final ByteData data = ByteData(4)..setFloat32(0, value, Endian.little);
    _builder.add(data.buffer.asUint8List());
  }

  Uint8List takeBytes() => _builder.takeBytes();

  void _tag(int field, int wireType) => _varint((field << 3) | wireType);

  void _varint(int value) => _writeVarint(_builder, value);

  static void _writeVarint(BytesBuilder builder, int value) {
    int remaining = value;
    while (remaining >= 0x80) {
      builder.addByte((remaining & 0x7f) | 0x80);
      remaining >>= 7;
    }
    builder.addByte(remaining);
  }
}
