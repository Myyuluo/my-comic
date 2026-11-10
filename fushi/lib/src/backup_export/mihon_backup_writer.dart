import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/backup_import/mihon_backup_parser.dart';

/// Hand-written gzip + protobuf encoder for the Mihon v0.21.3 backup surface.
///
/// It mirrors [MihonBackupParser] field-for-field, so anything this writer emits
/// round-trips through the importer. Field numbers are copied from Mihon
/// v0.21.3 `eu.kanade.tachiyomi.data.backup.models.*`; see ADR 0005/0007.
///
/// Proto3 semantics: default scalars are omitted. The one deliberate exception
/// is `BackupManga.favorite`, whose Kotlin default is `true`; only the
/// `false` case is written.
class MihonBackupWriter {
  const MihonBackupWriter();

  /// Uncompressed protobuf payload. Mihon accepts both compressed and
  /// uncompressed containers; [encodeGzip] is what the exporter writes.
  Uint8List encode(MihonBackupData data) {
    final _ProtoWriter top = _ProtoWriter();
    for (final MihonBackupManga manga in data.mangas) {
      top.bytes(1, _encodeManga(manga));
    }
    for (final MihonBackupCategory category in data.categories) {
      top.bytes(2, _encodeCategory(category));
    }
    for (final MapEntry<int, String> source in data.sourceNames.entries) {
      top.bytes(101, _encodeSource(source.key, source.value));
    }
    for (final MihonBackupPreference preference in data.preferences) {
      top.bytes(104, _encodePreference(preference));
    }
    for (final MihonBackupSourcePreferences preferences
        in data.sourcePreferences) {
      top.bytes(105, _encodeSourcePreferences(preferences));
    }
    for (final MihonBackupExtensionStore store in data.extensionStores) {
      top.bytes(106, _encodeExtensionStore(store));
    }
    return top.takeBytes();
  }

  Uint8List encodeGzip(MihonBackupData data) =>
      Uint8List.fromList(gzip.encode(encode(data)));

  Uint8List _encodeManga(MihonBackupManga manga) {
    final _ProtoWriter w = _ProtoWriter();
    w.varintOrOmit(1, manga.source);
    w.stringOrOmit(2, manga.url);
    w.stringOrOmit(3, manga.title);
    w.stringOrOmit(4, manga.artist);
    w.stringOrOmit(5, manga.author);
    w.stringOrOmit(6, manga.description);
    for (final String genre in manga.genres) {
      w.stringOrOmit(7, genre);
    }
    w.varintOrOmit(8, manga.status);
    w.stringOrOmit(9, manga.thumbnailUrl);
    w.varintOrOmit(13, manga.dateAdded);
    for (final MihonBackupChapter chapter in manga.chapters) {
      w.bytes(16, _encodeChapter(chapter));
    }
    if (manga.categoryOrders.isNotEmpty) {
      w.packedVarints(17, manga.categoryOrders);
    }
    for (final MihonBackupHistory history in manga.history) {
      w.bytes(104, _encodeHistory(history));
    }
    for (final MihonBackupTracking tracking in manga.tracking) {
      w.bytes(18, _encodeTracking(tracking));
    }
    // `favorite` defaults to true in the Kotlin model; write only the false
    // case so a normal library entry stays byte-identical to Mihon's output.
    if (!manga.favorite) w.varint(100, 0);
    return w.takeBytes();
  }

  Uint8List _encodeChapter(MihonBackupChapter chapter) {
    final _ProtoWriter w = _ProtoWriter();
    w.stringOrOmit(1, chapter.url);
    w.stringOrOmit(2, chapter.name);
    w.stringOrOmit(3, chapter.scanlator);
    if (chapter.read) w.varint(4, 1);
    if (chapter.bookmark) w.varint(5, 1);
    w.varintOrOmit(6, chapter.lastPageRead);
    w.varintOrOmit(7, chapter.dateFetch);
    w.varintOrOmit(8, chapter.dateUpload);
    w.float32OrOmit(9, chapter.chapterNumber);
    w.varintOrOmit(10, chapter.sourceOrder);
    return w.takeBytes();
  }

  Uint8List _encodeHistory(MihonBackupHistory history) {
    final _ProtoWriter w = _ProtoWriter();
    w.stringOrOmit(1, history.url);
    w.varintOrOmit(2, history.lastRead);
    w.varintOrOmit(3, history.readDuration);
    return w.takeBytes();
  }

  Uint8List _encodeTracking(MihonBackupTracking tracking) {
    final _ProtoWriter w = _ProtoWriter();
    w.varintOrOmit(1, tracking.syncId);
    w.varintOrOmit(2, tracking.libraryId);
    w.varintOrOmit(3, tracking.mediaIdInt);
    w.stringOrOmit(4, tracking.trackingUrl);
    w.stringOrOmit(5, tracking.title);
    w.float32OrOmit(6, tracking.lastChapterRead);
    w.varintOrOmit(7, tracking.totalChapters);
    w.float32OrOmit(8, tracking.score);
    w.varintOrOmit(9, tracking.status);
    w.varintOrOmit(10, tracking.startedReadingDate);
    w.varintOrOmit(11, tracking.finishedReadingDate);
    if (tracking.private) w.varint(12, 1);
    w.varintOrOmit(100, tracking.mediaId);
    return w.takeBytes();
  }

  Uint8List _encodeCategory(MihonBackupCategory category) {
    final _ProtoWriter w = _ProtoWriter();
    w.stringOrOmit(1, category.name);
    w.varintOrOmit(2, category.order);
    w.varintOrOmit(3, category.id);
    return w.takeBytes();
  }

  Uint8List _encodeSource(int id, String name) {
    final _ProtoWriter w = _ProtoWriter();
    w.stringOrOmit(1, name);
    w.varintOrOmit(2, id);
    return w.takeBytes();
  }

  Uint8List _encodeSourcePreferences(MihonBackupSourcePreferences preferences) {
    final _ProtoWriter w = _ProtoWriter();
    w.stringOrOmit(1, preferences.sourceKey);
    for (final MihonBackupPreference preference in preferences.preferences) {
      w.bytes(2, _encodePreference(preference));
    }
    return w.takeBytes();
  }

  Uint8List _encodePreference(MihonBackupPreference preference) {
    final _ProtoWriter w = _ProtoWriter();
    w.stringOrOmit(1, preference.key);
    w.bytes(2, _encodePreferenceValue(preference.value));
    return w.takeBytes();
  }

  /// kotlinx.serialization protobuf polymorphic envelope:
  /// `{1: fully-qualified serial name, 2: payload message}` where the payload
  /// stores the subclass value at field 1.
  ///
  /// Only Mihon's six standard value types are legal. An unknown serial name
  /// aborts Mihon's whole restore, so an unsupported value is a programming
  /// error here rather than something to write.
  Uint8List _encodePreferenceValue(MihonBackupPreferenceValue value) {
    final _ProtoWriter payload = _ProtoWriter();
    switch (value.type) {
      case MihonBackupPreferenceType.string:
        payload.stringOrOmit(1, value.value as String?);
      case MihonBackupPreferenceType.boolean:
        if (value.value == true) payload.varint(1, 1);
      case MihonBackupPreferenceType.integer:
        payload.varintOrOmit(1, value.value as int?);
      case MihonBackupPreferenceType.long:
        payload.varintOrOmit(1, value.value as int?);
      case MihonBackupPreferenceType.float:
        payload.float32OrOmit(1, value.value as double?);
      case MihonBackupPreferenceType.stringSet:
        final Object? raw = value.value;
        for (final String item
            in raw is List<String> ? raw : const <String>[]) {
          payload.stringOrOmit(1, item);
        }
      case MihonBackupPreferenceType.unsupported:
        // Serial name resolution below throws the same diagnostic; keeping an
        // explicit branch makes the invalid state impossible to miss.
        throw ArgumentError(
          'A .tachibk backup may only contain the six standard Mihon '
          'preference value types; got unsupported.',
        );
    }

    final _ProtoWriter envelope = _ProtoWriter();
    envelope.string(1, MihonBackupPreferenceTypes.serialName(value.type));
    // Write the payload message even when it is empty: the parser (and Mihon)
    // distinguish "missing payload" from "payload with default value".
    envelope.bytes(2, payload.takeBytes());
    return envelope.takeBytes();
  }

  Uint8List _encodeExtensionStore(MihonBackupExtensionStore store) {
    final _ProtoWriter w = _ProtoWriter();
    w.stringOrOmit(1, store.indexUrl);
    w.stringOrOmit(2, store.name);
    w.stringOrOmit(3, store.badgeLabel);
    w.stringOrOmit(4, store.contactWebsite);
    w.stringOrOmit(5, store.signingKey);
    if (store.contactDiscord != null) {
      w.string(6, store.contactDiscord!);
    }
    if (store.isLegacy != null) {
      w.varint(7, store.isLegacy! ? 1 : 0);
    }
    if (store.extensionListUrl != null) {
      w.string(8, store.extensionListUrl!);
    }
    return w.takeBytes();
  }
}

/// Minimal protobuf wire-format writer over the field kinds the backup uses.
class _ProtoWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void varint(int field, int value) {
    _tag(field, 0);
    _varint(value);
  }

  /// Proto3 omits zero-valued varint scalars.
  void varintOrOmit(int field, int? value) {
    if (value == null || value == 0) return;
    varint(field, value);
  }

  void string(int field, String value) {
    bytes(field, utf8.encode(value));
  }

  /// Proto3 omits empty / absent strings.
  void stringOrOmit(int field, String? value) {
    if (value == null || value.isEmpty) return;
    string(field, value);
  }

  void bytes(int field, List<int> value) {
    _tag(field, 2);
    _varint(value.length);
    _builder.add(value);
  }

  void packedVarints(int field, List<int> values) {
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

  /// Proto3 omits zero-valued floats.
  void float32OrOmit(int field, double? value) {
    if (value == null || value == 0) return;
    float32(field, value);
  }

  Uint8List takeBytes() => _builder.takeBytes();

  void _tag(int field, int wireType) => _varint((field << 3) | wireType);

  void _varint(int value) => _writeVarint(_builder, value);

  static void _writeVarint(BytesBuilder builder, int value) {
    int remaining = value;
    // Negative int32/int64 values are sign-extended to a 64-bit unsigned
    // varint (10 bytes); `>>>` keeps the loop from spinning on -1.
    while (remaining < 0 || remaining >= 0x80) {
      builder.addByte((remaining & 0x7f) | 0x80);
      remaining >>>= 7;
    }
    builder.addByte(remaining);
  }
}
