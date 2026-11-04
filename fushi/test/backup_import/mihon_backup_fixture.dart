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

/// Writes a gzip-compressed Mihon backup file into [directory].
Future<File> writeFixtureBackup(
  Directory directory, {
  required List<FixtureManga> mangas,
  List<FixtureCategory> categories = const <FixtureCategory>[],
  List<FixtureSource> sources = const <FixtureSource>[],
  bool gzip = true,
  String name = 'fixture.tachibk',
}) async {
  final Uint8List payload = encodeFixtureBackup(
    mangas: mangas,
    categories: categories,
    sources: sources,
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
