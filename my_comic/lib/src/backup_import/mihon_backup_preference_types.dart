/// Mihon v0.21.3 preference value types and their single-owner mappings.
///
/// The parser, writer, exporter and importer all speak the same six standard
/// value envelopes. Their wire names, Dart value shapes and MyComic's source
/// preference labels are defined here once so a new type or a renamed envelope
/// can never drift between the read and write sides.
library;

/// The six standard Mihon preference value types, plus the parser's marker for
/// an unknown serial name.
///
/// [unsupported] is never legal in a backup MyComic writes: Mihon aborts the
/// whole restore on an unknown serial name (ADR 0019).
enum MihonBackupPreferenceType {
  string,
  boolean,
  integer,
  long,
  float,
  stringSet,
  unsupported,
}

class MihonBackupPreferenceValue {
  const MihonBackupPreferenceValue({required this.type, this.value});

  final MihonBackupPreferenceType type;

  /// `String`, `bool`, `int`, `double` or `List<String>` depending on [type].
  final Object? value;
}

/// One source of truth for Mihon's preference type mappings.
abstract final class MihonBackupPreferenceTypes {
  /// Fully-qualified namespace Mihon writes into the polymorphic envelope.
  static const String serialNamespace =
      'eu.kanade.tachiyomi.data.backup.models.';

  static const Map<String, MihonBackupPreferenceType> bySerialSimpleName =
      <String, MihonBackupPreferenceType>{
        'StringPreferenceValue': MihonBackupPreferenceType.string,
        'BooleanPreferenceValue': MihonBackupPreferenceType.boolean,
        'IntPreferenceValue': MihonBackupPreferenceType.integer,
        'LongPreferenceValue': MihonBackupPreferenceType.long,
        'FloatPreferenceValue': MihonBackupPreferenceType.float,
        'StringSetPreferenceValue': MihonBackupPreferenceType.stringSet,
      };

  /// Parses the simple class name of Mihon's serialized value envelope.
  /// Unknown names map to [MihonBackupPreferenceType.unsupported].
  static MihonBackupPreferenceType fromSerialName(String serialName) =>
      bySerialSimpleName[serialName.split('.').last] ??
      MihonBackupPreferenceType.unsupported;

  /// Simple envelope class name, or null for [unsupported].
  static String? serialSimpleName(MihonBackupPreferenceType type) =>
      switch (type) {
        MihonBackupPreferenceType.string => 'StringPreferenceValue',
        MihonBackupPreferenceType.boolean => 'BooleanPreferenceValue',
        MihonBackupPreferenceType.integer => 'IntPreferenceValue',
        MihonBackupPreferenceType.long => 'LongPreferenceValue',
        MihonBackupPreferenceType.float => 'FloatPreferenceValue',
        MihonBackupPreferenceType.stringSet => 'StringSetPreferenceValue',
        MihonBackupPreferenceType.unsupported => null,
      };

  /// Fully-qualified serial name written into the envelope.
  ///
  /// Throws for [MihonBackupPreferenceType.unsupported]: writing an unknown
  /// serial name would abort Mihon's whole restore.
  static String serialName(MihonBackupPreferenceType type) {
    final String? simpleName = serialSimpleName(type);
    if (simpleName == null) {
      throw ArgumentError(
        'A .tachibk backup may only contain the six standard Mihon '
        'preference value types; got unsupported.',
      );
    }
    return '$serialNamespace$simpleName';
  }

  /// Maps a Dart preference value (PrefCodec- or JSON-decoded) onto Mihon's
  /// standard envelope. Returns null for shapes no standard envelope can carry
  /// (explicit null, JSON objects, non-string lists): those rows are skipped
  /// instead of writing a value Mihon cannot restore.
  static MihonBackupPreferenceValue? fromDartValue(Object? value) {
    if (value is bool) {
      return MihonBackupPreferenceValue(
        type: MihonBackupPreferenceType.boolean,
        value: value,
      );
    }
    if (value is int) {
      final bool fitsInt32 = value >= -0x80000000 && value <= 0x7fffffff;
      return MihonBackupPreferenceValue(
        type: fitsInt32
            ? MihonBackupPreferenceType.integer
            : MihonBackupPreferenceType.long,
        value: value,
      );
    }
    if (value is double) {
      return MihonBackupPreferenceValue(
        type: MihonBackupPreferenceType.float,
        value: value,
      );
    }
    if (value is String) {
      return MihonBackupPreferenceValue(
        type: MihonBackupPreferenceType.string,
        value: value,
      );
    }
    if (value is List && value.every((Object? item) => item is String)) {
      return MihonBackupPreferenceValue(
        type: MihonBackupPreferenceType.stringSet,
        value: List<String>.from(value),
      );
    }
    return null;
  }

  /// Whether [value] has the Dart shape [type] promises. [unsupported] never
  /// matches: it aborts an import before any write.
  static bool matchesValue(MihonBackupPreferenceType type, Object? value) =>
      switch (type) {
        MihonBackupPreferenceType.string => value is String,
        MihonBackupPreferenceType.boolean => value is bool,
        MihonBackupPreferenceType.integer ||
        MihonBackupPreferenceType.long => value is int,
        MihonBackupPreferenceType.float => value is double,
        MihonBackupPreferenceType.stringSet => value is List<String>,
        MihonBackupPreferenceType.unsupported => false,
      };

  /// MyComic `manga_source_preferences.preference_type` label.
  static String sourcePreferenceTypeName(MihonBackupPreferenceType type) =>
      switch (type) {
        MihonBackupPreferenceType.string => 'text',
        MihonBackupPreferenceType.boolean => 'checkBox',
        MihonBackupPreferenceType.stringSet => 'multiSelect',
        MihonBackupPreferenceType.integer ||
        MihonBackupPreferenceType.long ||
        MihonBackupPreferenceType.float ||
        MihonBackupPreferenceType.unsupported => 'unsupported',
      };
}
