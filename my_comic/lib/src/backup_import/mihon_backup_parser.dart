import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:my_comic/src/backup_import/mihon_backup_preference_types.dart';

export 'mihon_backup_preference_types.dart';

/// Why a `.tachibk` file could not be read.
enum MihonBackupFormatError {
  /// Zero-byte file.
  emptyFile,

  /// The container is plausible but its protobuf payload is malformed/truncated.
  corrupt,

  /// Not a Mihon backup (e.g. a JSON backup from Mihon 1.x).
  unsupportedFormat,
}

class MihonBackupFormatException implements Exception {
  const MihonBackupFormatException(this.error, [this.detail]);

  final MihonBackupFormatError error;
  final String? detail;

  @override
  String toString() =>
      'MihonBackupFormatException: ${error.name}'
      '${detail == null ? '' : ' ($detail)'}';
}

/// Minimal decoder for the Mihon v0.21.3 backup protobuf surface.
///
/// ADR-0005 prefers reusing Mihon's Kotlin backup classes in the JVM sidecar.
/// This ticket ships the documented Dart fallback (gzip + protobuf wire format)
/// so the import path stays testable without a sidecar build. Field numbers are
/// copied from Mihon v0.21.3
/// `app/src/main/java/eu/kanade/tachiyomi/data/backup/models/*.kt`.
class MihonBackupParser {
  const MihonBackupParser._();

  static MihonBackupData parseFile(File file) {
    return parseBytes(file.readAsBytesSync());
  }

  static MihonBackupData parseBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const MihonBackupFormatException(MihonBackupFormatError.emptyFile);
    }

    final Uint8List payload;
    if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      try {
        payload = Uint8List.fromList(gzip.decode(bytes));
      } on Object catch (error) {
        throw MihonBackupFormatException(
          MihonBackupFormatError.corrupt,
          'gzip: $error',
        );
      }
    } else if (bytes[0] == 0x7b) {
      // Mihon 1.x JSON backups ({}, {" or {\n) are explicitly unsupported.
      throw const MihonBackupFormatException(
        MihonBackupFormatError.unsupportedFormat,
        'JSON backups are not supported',
      );
    } else {
      // Mihon's decoder also accepts uncompressed protobuf payloads.
      payload = bytes;
    }

    try {
      return _readBackup(_ProtoReader(payload));
    } on MihonBackupFormatException {
      rethrow;
    } on Object catch (error) {
      throw MihonBackupFormatException(
        MihonBackupFormatError.corrupt,
        '$error',
      );
    }
  }

  static MihonBackupData _readBackup(_ProtoReader reader) {
    final List<MihonBackupManga> mangas = <MihonBackupManga>[];
    final List<MihonBackupCategory> categories = <MihonBackupCategory>[];
    final Map<int, String> sourceNames = <int, String>{};
    final List<MihonBackupPreference> preferences = <MihonBackupPreference>[];
    final List<MihonBackupSourcePreferences> sourcePreferences =
        <MihonBackupSourcePreferences>[];
    final List<MihonBackupExtensionStore> extensionStores =
        <MihonBackupExtensionStore>[];

    while (!reader.isAtEnd) {
      final int tag = reader.readTag();
      final int field = tag >> 3;
      final int wireType = tag & 0x7;
      if (field == 0) {
        throw const MihonBackupFormatException(
          MihonBackupFormatError.corrupt,
          'invalid field number 0',
        );
      }
      if (field == 1 && wireType == 2) {
        mangas.add(_readManga(_ProtoReader(reader.readBytes())));
      } else if (field == 2 && wireType == 2) {
        categories.add(_readCategory(_ProtoReader(reader.readBytes())));
      } else if (field == 101 && wireType == 2) {
        final MihonBackupSource source = _readSource(
          _ProtoReader(reader.readBytes()),
        );
        if (source.name.isNotEmpty) {
          sourceNames[source.id] = source.name;
        }
      } else if (field == 104 && wireType == 2) {
        preferences.add(_readPreference(_ProtoReader(reader.readBytes())));
      } else if (field == 105 && wireType == 2) {
        sourcePreferences.add(
          _readSourcePreferences(_ProtoReader(reader.readBytes())),
        );
      } else if (field == 106 && wireType == 2) {
        extensionStores.add(
          _readExtensionStore(_ProtoReader(reader.readBytes())),
        );
      } else {
        reader.skip(wireType);
      }
    }

    return MihonBackupData(
      mangas: List<MihonBackupManga>.unmodifiable(mangas),
      categories: List<MihonBackupCategory>.unmodifiable(categories),
      sourceNames: Map<int, String>.unmodifiable(sourceNames),
      preferences: List<MihonBackupPreference>.unmodifiable(preferences),
      sourcePreferences: List<MihonBackupSourcePreferences>.unmodifiable(
        sourcePreferences,
      ),
      extensionStores: List<MihonBackupExtensionStore>.unmodifiable(
        extensionStores,
      ),
    );
  }

  static MihonBackupManga _readManga(_ProtoReader reader) {
    int source = 0;
    String url = '';
    String title = '';
    String? artist;
    String? author;
    String? description;
    final List<String> genres = <String>[];
    int status = 0;
    String? thumbnailUrl;
    int dateAdded = 0;
    bool favorite = true;
    final List<MihonBackupChapter> chapters = <MihonBackupChapter>[];
    final List<int> categoryOrders = <int>[];
    final List<MihonBackupHistory> history = <MihonBackupHistory>[];
    final List<MihonBackupTracking> tracking = <MihonBackupTracking>[];

    while (!reader.isAtEnd) {
      final int tag = reader.readTag();
      final int field = tag >> 3;
      final int wireType = tag & 0x7;
      switch (field) {
        case 1 when wireType == 0:
          source = reader.readVarint();
        case 2 when wireType == 2:
          url = reader.readString();
        case 3 when wireType == 2:
          title = reader.readString();
        case 4 when wireType == 2:
          artist = reader.readString();
        case 5 when wireType == 2:
          author = reader.readString();
        case 6 when wireType == 2:
          description = reader.readString();
        case 7 when wireType == 2:
          genres.add(reader.readString());
        case 8 when wireType == 0:
          status = reader.readVarint();
        case 9 when wireType == 2:
          thumbnailUrl = reader.readString();
        case 13 when wireType == 0:
          dateAdded = reader.readVarint();
        case 16 when wireType == 2:
          chapters.add(_readChapter(_ProtoReader(reader.readBytes())));
        case 17 when wireType == 0:
          categoryOrders.add(reader.readVarint());
        case 17 when wireType == 2:
          final _ProtoReader packed = _ProtoReader(reader.readBytes());
          while (!packed.isAtEnd) {
            categoryOrders.add(packed.readVarint());
          }
        case 18 when wireType == 2:
          tracking.add(_readTracking(_ProtoReader(reader.readBytes())));
        case 100 when wireType == 0:
          favorite = reader.readVarint() != 0;
        case 104 when wireType == 2:
          history.add(_readHistory(_ProtoReader(reader.readBytes())));
        default:
          reader.skip(wireType);
      }
    }

    return MihonBackupManga(
      source: source,
      url: url,
      title: title,
      artist: _emptyToNull(artist),
      author: _emptyToNull(author),
      description: _emptyToNull(description),
      genres: List<String>.unmodifiable(genres),
      status: status,
      thumbnailUrl: _emptyToNull(thumbnailUrl),
      dateAdded: dateAdded,
      favorite: favorite,
      chapters: List<MihonBackupChapter>.unmodifiable(chapters),
      categoryOrders: List<int>.unmodifiable(categoryOrders),
      history: List<MihonBackupHistory>.unmodifiable(history),
      tracking: List<MihonBackupTracking>.unmodifiable(tracking),
    );
  }

  static MihonBackupTracking _readTracking(_ProtoReader reader) {
    int syncId = 0;
    int? libraryId;
    int? mediaIdInt;
    String trackingUrl = '';
    String title = '';
    double lastChapterRead = 0;
    int totalChapters = 0;
    double score = 0;
    int status = 0;
    int? startedReadingDate;
    int? finishedReadingDate;
    bool private = false;
    int? mediaId;

    while (!reader.isAtEnd) {
      final int tag = reader.readTag();
      final int field = tag >> 3;
      final int wireType = tag & 0x7;
      switch (field) {
        case 1 when wireType == 0:
          syncId = reader.readVarint();
        case 2 when wireType == 0:
          libraryId = _zeroToNull(reader.readVarint());
        case 3 when wireType == 0:
          mediaIdInt = _zeroToNull(reader.readVarint());
        case 4 when wireType == 2:
          trackingUrl = reader.readString();
        case 5 when wireType == 2:
          title = reader.readString();
        case 6 when wireType == 5:
          lastChapterRead = reader.readFloat32();
        case 7 when wireType == 0:
          totalChapters = reader.readVarint();
        case 8 when wireType == 5:
          score = reader.readFloat32();
        case 9 when wireType == 0:
          status = reader.readVarint();
        case 10 when wireType == 0:
          startedReadingDate = _zeroToNull(reader.readVarint());
        case 11 when wireType == 0:
          finishedReadingDate = _zeroToNull(reader.readVarint());
        case 12 when wireType == 0:
          private = reader.readVarint() != 0;
        case 100 when wireType == 0:
          mediaId = _zeroToNull(reader.readVarint());
        default:
          reader.skip(wireType);
      }
    }

    return MihonBackupTracking(
      syncId: syncId,
      libraryId: libraryId,
      mediaIdInt: mediaIdInt,
      trackingUrl: trackingUrl,
      title: title,
      lastChapterRead: lastChapterRead,
      totalChapters: totalChapters,
      score: score,
      status: status,
      startedReadingDate: startedReadingDate,
      finishedReadingDate: finishedReadingDate,
      private: private,
      mediaId: mediaId,
    );
  }

  static MihonBackupSourcePreferences _readSourcePreferences(
    _ProtoReader reader,
  ) {
    String sourceKey = '';
    final List<MihonBackupPreference> preferences = <MihonBackupPreference>[];
    while (!reader.isAtEnd) {
      final int tag = reader.readTag();
      final int field = tag >> 3;
      final int wireType = tag & 0x7;
      switch (field) {
        case 1 when wireType == 2:
          sourceKey = reader.readString();
        case 2 when wireType == 2:
          preferences.add(_readPreference(_ProtoReader(reader.readBytes())));
        default:
          reader.skip(wireType);
      }
    }
    return MihonBackupSourcePreferences(
      sourceKey: sourceKey,
      preferences: List<MihonBackupPreference>.unmodifiable(preferences),
    );
  }

  static MihonBackupPreference _readPreference(_ProtoReader reader) {
    String key = '';
    MihonBackupPreferenceValue value = const MihonBackupPreferenceValue(
      type: MihonBackupPreferenceType.unsupported,
    );
    while (!reader.isAtEnd) {
      final int tag = reader.readTag();
      final int field = tag >> 3;
      final int wireType = tag & 0x7;
      switch (field) {
        case 1 when wireType == 2:
          key = reader.readString();
        case 2 when wireType == 2:
          value = _readPreferenceValue(_ProtoReader(reader.readBytes()));
        default:
          reader.skip(wireType);
      }
    }
    return MihonBackupPreference(key: key, value: value);
  }

  /// kotlinx.serialization protobuf polymorphic envelope:
  /// `{1: serial name, 2: payload message}` where the payload stores the
  /// subclass value at field 1.
  static MihonBackupPreferenceValue _readPreferenceValue(_ProtoReader reader) {
    String serialName = '';
    Uint8List? payload;
    while (!reader.isAtEnd) {
      final int tag = reader.readTag();
      final int field = tag >> 3;
      final int wireType = tag & 0x7;
      switch (field) {
        case 1 when wireType == 2:
          serialName = reader.readString();
        case 2 when wireType == 2:
          payload = reader.readBytes();
        default:
          reader.skip(wireType);
      }
    }

    final String simpleName = serialName.split('.').last;
    final MihonBackupPreferenceType type =
        MihonBackupPreferenceTypes.fromSerialName(simpleName);
    if (payload == null) {
      return MihonBackupPreferenceValue(type: type);
    }

    final _ProtoReader values = _ProtoReader(payload);
    Object? value;
    while (!values.isAtEnd) {
      final int tag = values.readTag();
      final int field = tag >> 3;
      final int wireType = tag & 0x7;
      if (field != 1) {
        values.skip(wireType);
        continue;
      }
      switch (type) {
        case MihonBackupPreferenceType.string when wireType == 2:
          value = values.readString();
        case MihonBackupPreferenceType.boolean when wireType == 0:
          value = values.readVarint() != 0;
        case MihonBackupPreferenceType.integer when wireType == 0:
          value = values.readVarint();
        case MihonBackupPreferenceType.long when wireType == 0:
          value = values.readVarint();
        case MihonBackupPreferenceType.float when wireType == 5:
          value = values.readFloat32();
        case MihonBackupPreferenceType.stringSet when wireType == 2:
          value = <String>[
            ...(value as List<String>? ?? const <String>[]),
            values.readString(),
          ];
        default:
          values.skip(wireType);
      }
    }
    return MihonBackupPreferenceValue(
      type: type,
      // Proto3 omits zero-valued scalars; restore the type's default so an
      // empty string / false / 0 preference is still imported.
      value:
          value ??
          switch (type) {
            MihonBackupPreferenceType.string => '',
            MihonBackupPreferenceType.boolean => false,
            MihonBackupPreferenceType.integer => 0,
            MihonBackupPreferenceType.long => 0,
            MihonBackupPreferenceType.float => 0.0,
            MihonBackupPreferenceType.stringSet => <String>[],
            MihonBackupPreferenceType.unsupported => null,
          },
    );
  }

  static MihonBackupExtensionStore _readExtensionStore(_ProtoReader reader) {
    String indexUrl = '';
    String name = '';
    String? badgeLabel;
    String signingKey = '';
    String contactWebsite = '';
    String? contactDiscord;
    bool? isLegacy;
    String? extensionListUrl;
    while (!reader.isAtEnd) {
      final int tag = reader.readTag();
      final int field = tag >> 3;
      final int wireType = tag & 0x7;
      switch (field) {
        case 1 when wireType == 2:
          indexUrl = reader.readString();
        case 2 when wireType == 2:
          name = reader.readString();
        case 3 when wireType == 2:
          badgeLabel = _emptyToNull(reader.readString());
        case 4 when wireType == 2:
          contactWebsite = reader.readString();
        case 5 when wireType == 2:
          signingKey = reader.readString();
        case 6 when wireType == 2:
          contactDiscord = _emptyToNull(reader.readString());
        case 7 when wireType == 0:
          isLegacy = reader.readVarint() != 0;
        case 8 when wireType == 2:
          extensionListUrl = _emptyToNull(reader.readString());
        default:
          reader.skip(wireType);
      }
    }
    return MihonBackupExtensionStore(
      indexUrl: indexUrl,
      name: name,
      badgeLabel: badgeLabel,
      signingKey: signingKey,
      contactWebsite: contactWebsite,
      contactDiscord: contactDiscord,
      isLegacy: isLegacy,
      extensionListUrl: extensionListUrl,
    );
  }

  static MihonBackupChapter _readChapter(_ProtoReader reader) {
    String url = '';
    String name = '';
    String? scanlator;
    bool read = false;
    bool bookmark = false;
    int lastPageRead = 0;
    int dateFetch = 0;
    int dateUpload = 0;
    double chapterNumber = 0;
    int sourceOrder = 0;

    while (!reader.isAtEnd) {
      final int tag = reader.readTag();
      final int field = tag >> 3;
      final int wireType = tag & 0x7;
      switch (field) {
        case 1 when wireType == 2:
          url = reader.readString();
        case 2 when wireType == 2:
          name = reader.readString();
        case 3 when wireType == 2:
          scanlator = reader.readString();
        case 4 when wireType == 0:
          read = reader.readVarint() != 0;
        case 5 when wireType == 0:
          bookmark = reader.readVarint() != 0;
        case 6 when wireType == 0:
          lastPageRead = reader.readVarint();
        case 7 when wireType == 0:
          dateFetch = reader.readVarint();
        case 8 when wireType == 0:
          dateUpload = reader.readVarint();
        case 9 when wireType == 5:
          chapterNumber = reader.readFloat32();
        case 10 when wireType == 0:
          sourceOrder = reader.readVarint();
        default:
          reader.skip(wireType);
      }
    }

    return MihonBackupChapter(
      url: url,
      name: name,
      scanlator: _emptyToNull(scanlator),
      read: read,
      bookmark: bookmark,
      lastPageRead: lastPageRead,
      dateFetch: dateFetch,
      dateUpload: dateUpload,
      chapterNumber: chapterNumber,
      sourceOrder: sourceOrder,
    );
  }

  static MihonBackupHistory _readHistory(_ProtoReader reader) {
    String url = '';
    int lastRead = 0;
    int readDuration = 0;
    while (!reader.isAtEnd) {
      final int tag = reader.readTag();
      final int field = tag >> 3;
      final int wireType = tag & 0x7;
      switch (field) {
        case 1 when wireType == 2:
          url = reader.readString();
        case 2 when wireType == 0:
          lastRead = reader.readVarint();
        case 3 when wireType == 0:
          readDuration = reader.readVarint();
        default:
          reader.skip(wireType);
      }
    }
    return MihonBackupHistory(
      url: url,
      lastRead: lastRead,
      readDuration: readDuration,
    );
  }

  static MihonBackupCategory _readCategory(_ProtoReader reader) {
    String name = '';
    int order = 0;
    int id = 0;
    while (!reader.isAtEnd) {
      final int tag = reader.readTag();
      final int field = tag >> 3;
      final int wireType = tag & 0x7;
      switch (field) {
        case 1 when wireType == 2:
          name = reader.readString();
        case 2 when wireType == 0:
          order = reader.readVarint();
        case 3 when wireType == 0:
          id = reader.readVarint();
        default:
          reader.skip(wireType);
      }
    }
    return MihonBackupCategory(name: name, order: order, id: id);
  }

  static MihonBackupSource _readSource(_ProtoReader reader) {
    String name = '';
    int id = 0;
    while (!reader.isAtEnd) {
      final int tag = reader.readTag();
      final int field = tag >> 3;
      final int wireType = tag & 0x7;
      switch (field) {
        case 1 when wireType == 2:
          name = reader.readString();
        case 2 when wireType == 0:
          id = reader.readVarint();
        default:
          reader.skip(wireType);
      }
    }
    return MihonBackupSource(id: id, name: name);
  }

  static String? _emptyToNull(String? value) {
    if (value == null || value.isEmpty) return null;
    return value;
  }

  /// Proto3 omits zero-valued scalars; the backup models use nullable ints for
  /// "not set" (timestamps, remote ids) so keep that distinction.
  static int? _zeroToNull(int value) => value == 0 ? null : value;
}

class MihonBackupData {
  const MihonBackupData({
    required this.mangas,
    required this.categories,
    required this.sourceNames,
    this.preferences = const <MihonBackupPreference>[],
    this.sourcePreferences = const <MihonBackupSourcePreferences>[],
    this.extensionStores = const <MihonBackupExtensionStore>[],
  });

  final List<MihonBackupManga> mangas;
  final List<MihonBackupCategory> categories;

  /// Backup source id → display name from `BackupSource` (field 101).
  final Map<int, String> sourceNames;

  /// Top-level `BackupPreferences` entries (field 104). MyComic writes its own
  /// app preference keys here without mapping them to Mihon key names.
  final List<MihonBackupPreference> preferences;

  /// Top-level `BackupSourcePreferences` entries (field 105).
  final List<MihonBackupSourcePreferences> sourcePreferences;

  /// Top-level `BackupExtensionStore` entries (field 106).
  final List<MihonBackupExtensionStore> extensionStores;
}

class MihonBackupManga {
  const MihonBackupManga({
    required this.source,
    required this.url,
    required this.title,
    required this.artist,
    required this.author,
    required this.description,
    required this.genres,
    required this.status,
    required this.thumbnailUrl,
    required this.dateAdded,
    required this.favorite,
    required this.chapters,
    required this.categoryOrders,
    required this.history,
    this.tracking = const <MihonBackupTracking>[],
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

  /// Proto default is `true` (omitted when true). Entries with `false` are
  /// "read manga not in library" that Mihon backs up for history continuity.
  final bool favorite;
  final List<MihonBackupChapter> chapters;

  /// `BackupManga.categories` stores category **order** values, not ids
  /// (`MangaBackupCreator.kt`); restore resolves order → `BackupCategory` name.
  final List<int> categoryOrders;
  final List<MihonBackupHistory> history;

  /// `BackupManga.tracking` (field 18).
  final List<MihonBackupTracking> tracking;
}

class MihonBackupChapter {
  const MihonBackupChapter({
    required this.url,
    required this.name,
    required this.scanlator,
    required this.read,
    required this.bookmark,
    required this.lastPageRead,
    required this.dateFetch,
    required this.dateUpload,
    required this.chapterNumber,
    this.sourceOrder = 0,
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

  /// `BackupChapter.sourceOrder` (proto field 10): the chapter's position in
  /// the source list. Preserved on export so Mihon keeps the reading order.
  final int sourceOrder;
}

class MihonBackupHistory {
  const MihonBackupHistory({
    required this.url,
    required this.lastRead,
    required this.readDuration,
  });

  final String url;
  final int lastRead;
  final int readDuration;
}

class MihonBackupCategory {
  const MihonBackupCategory({
    required this.name,
    required this.order,
    required this.id,
  });

  final String name;
  final int order;
  final int id;
}

class MihonBackupSource {
  const MihonBackupSource({required this.id, required this.name});

  final int id;
  final String name;
}

/// `BackupManga.tracking` entry. [syncId] is Mihon's tracker id
/// (`TrackerManager`: 1 MAL, 2 AniList, 3 Kitsu, 4 Shikimori, 5 Bangumi, …).
class MihonBackupTracking {
  const MihonBackupTracking({
    required this.syncId,
    required this.libraryId,
    required this.mediaIdInt,
    required this.trackingUrl,
    required this.title,
    required this.lastChapterRead,
    required this.totalChapters,
    required this.score,
    required this.status,
    required this.startedReadingDate,
    required this.finishedReadingDate,
    required this.private,
    required this.mediaId,
  });

  final int syncId;
  final int? libraryId;

  /// Deprecated `mediaId` (proto field 3) written by Mihon 1.x.
  final int? mediaIdInt;
  final String trackingUrl;
  final String title;
  final double lastChapterRead;
  final int totalChapters;
  final double score;
  final int status;
  final int? startedReadingDate;
  final int? finishedReadingDate;
  final bool private;

  /// Current remote id (proto field 100); takes precedence over [mediaIdInt].
  final int? mediaId;

  int? get remoteId => mediaId ?? mediaIdInt;
}

class MihonBackupSourcePreferences {
  const MihonBackupSourcePreferences({
    required this.sourceKey,
    required this.preferences,
  });

  /// Mihon's `ConfigurableSource.preferenceKey()` = `source_<sourceId>`.
  final String sourceKey;
  final List<MihonBackupPreference> preferences;
}

class MihonBackupPreference {
  const MihonBackupPreference({required this.key, required this.value});

  final String key;
  final MihonBackupPreferenceValue value;
}

/// `BackupExtensionStore` (top-level field 106). Unlike the source preference
/// values, these are plain protobuf fields, not a polymorphic envelope.
class MihonBackupExtensionStore {
  const MihonBackupExtensionStore({
    required this.indexUrl,
    required this.name,
    required this.badgeLabel,
    required this.signingKey,
    required this.contactWebsite,
    required this.contactDiscord,
    required this.isLegacy,
    required this.extensionListUrl,
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

/// Cursor over a protobuf wire-format message.
class _ProtoReader {
  _ProtoReader(this._bytes) : _view = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _view;
  int _position = 0;

  bool get isAtEnd => _position >= _bytes.length;

  int readTag() => readVarint();

  int readVarint() {
    int result = 0;
    int shift = 0;
    while (true) {
      _require(1);
      final int byte = _bytes[_position++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) return result;
      shift += 7;
      if (shift >= 64) {
        throw const MihonBackupFormatException(
          MihonBackupFormatError.corrupt,
          'varint too long',
        );
      }
    }
  }

  Uint8List readBytes() {
    final int length = readVarint();
    if (length < 0) {
      throw const MihonBackupFormatException(
        MihonBackupFormatError.corrupt,
        'negative length',
      );
    }
    _require(length);
    final Uint8List view = Uint8List.sublistView(
      _bytes,
      _position,
      _position + length,
    );
    _position += length;
    return view;
  }

  String readString() {
    return utf8.decode(readBytes(), allowMalformed: true);
  }

  double readFloat32() {
    _require(4);
    final double value = _view.getFloat32(_position, Endian.little);
    _position += 4;
    return value;
  }

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        readVarint();
      case 1:
        _require(8);
        _position += 8;
      case 2:
        final int length = readVarint();
        if (length < 0) {
          throw const MihonBackupFormatException(
            MihonBackupFormatError.corrupt,
            'negative length',
          );
        }
        _require(length);
        _position += length;
      case 5:
        _require(4);
        _position += 4;
      default:
        throw MihonBackupFormatException(
          MihonBackupFormatError.corrupt,
          'unsupported wire type $wireType',
        );
    }
  }

  void _require(int length) {
    if (_position + length > _bytes.length) {
      throw const MihonBackupFormatException(
        MihonBackupFormatError.corrupt,
        'truncated message',
      );
    }
  }
}
