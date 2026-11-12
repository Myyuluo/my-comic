part of 'mihon_backup_exporter.dart';

/// `MangaExtensionStores.format` 的历史值：老式仓库条目（Mihon 备份的 `isLegacy`）。
const String _kLegacyStoreFormat = 'legacy';

/// 「应用设置」: MyComic's own `preferences` rows under their original key
/// names, wrapped in Mihon's six standard value envelopes.
class _AppSettingsExportSection {
  const _AppSettingsExportSection(this.database);

  final MyComicDatabase database;

  /// MyComic keys are not mapped to Mihon key names on purpose (spec:
  /// 不做 Mihon 键名映射). Device-local rows never leave the device.
  Future<List<MihonBackupPreference>> load(
    MihonBackupExportOptions options,
  ) async {
    if (!options.includeAppSettings) {
      return const <MihonBackupPreference>[];
    }
    final Map<String, String> all = await database.getAllPrefs();
    // Stable order keeps backup bytes deterministic for a given database.
    final List<String> keys = all.keys.toList()..sort();
    final List<MihonBackupPreference> preferences = <MihonBackupPreference>[];
    for (final String key in keys) {
      if (!_shouldExportPreference(
        key,
        includeSensitive: options.includeSensitiveSettings,
      )) {
        continue;
      }
      final MihonBackupPreferenceValue? value = _preferenceValue(all[key]!);
      if (value == null) continue;
      preferences.add(MihonBackupPreference(key: key, value: value));
    }
    return preferences;
  }

  /// Device-local rows describe this device (paths, device ids, sync state) and
  /// never belong in a portable backup, sensitive checkbox or not. Credential
  /// rows use the existing [PrefRedactionPolicy] semantics and are only written
  /// when the user explicitly includes sensitive settings.
  static bool _shouldExportPreference(
    String key, {
    required bool includeSensitive,
  }) {
    // The prefs-version counter is a per-install cache-invalidation signal
    // written on every preference change, not a user setting.
    if (key == MyComicDatabase.prefsVersionKey) return false;
    if (PrefRedactionPolicy.isDeviceLocal(key)) return false;
    if (includeSensitive) return true;
    return !PrefRedactionPolicy.isDeviceLocalOrCredential(key);
  }

  /// Maps a [PrefCodec]-encoded row onto one of Mihon's six standard preference
  /// value envelopes. Returns null for shapes no standard envelope can carry
  /// (explicit null, JSON objects, non-string lists): Mihon aborts the whole
  /// restore on an unknown serial name, so those rows are skipped instead.
  static MihonBackupPreferenceValue? _preferenceValue(String raw) =>
      MihonBackupPreferenceTypes.fromDartValue(PrefCodec.decodeUntyped(raw));
}

/// 「插件商店」: every **manga** Extension store becomes a
/// `BackupExtensionStore`.
///
/// MyComic is a manga-only app, and the Mihon backup format has no media-kind
/// field, so Aniyomi (video) stores are deliberately excluded: exporting one
/// would recreate it as a manga store on the importing side (ADR 0019).
class _MangaExtensionStoreExportSection {
  const _MangaExtensionStoreExportSection(this.database);

  final MyComicDatabase database;

  Future<List<MihonBackupExtensionStore>> load(
    MihonBackupExportOptions options,
  ) async {
    if (!options.includeExtensionStores) {
      return const <MihonBackupExtensionStore>[];
    }
    final List<MangaExtensionStoreRow> rows = await database
        .getMangaExtensionStores(mediaKind: 'manga');
    final List<MihonBackupExtensionStore> stores =
        <MihonBackupExtensionStore>[];
    for (final MangaExtensionStoreRow row in rows) {
      final Map<String, String?> contact = _storeContact(row.contactJson);
      stores.add(
        MihonBackupExtensionStore(
          indexUrl: row.indexUrl,
          name: row.name,
          badgeLabel: row.badgeLabel,
          signingKey: row.signingKey ?? '',
          contactWebsite: (contact['website'] ?? '').trim(),
          contactDiscord: _nonEmpty((contact['discord'] ?? '').trim()),
          isLegacy: row.format == _kLegacyStoreFormat,
          extensionListUrl: row.extensionListUrl,
        ),
      );
    }
    return stores;
  }

  /// `MangaExtensionStores.contactJson` = `{"website": …, "discord": …}`.
  /// Malformed metadata must not abort the whole backup, so it reads as empty.
  static Map<String, String?> _storeContact(String? contactJson) {
    if (contactJson == null || contactJson.trim().isEmpty) {
      return const <String, String?>{};
    }
    try {
      final Object? decoded = jsonDecode(contactJson);
      if (decoded is! Map) return const <String, String?>{};
      return <String, String?>{
        for (final MapEntry<Object?, Object?> entry in decoded.entries)
          entry.key.toString(): entry.value?.toString(),
      };
    } on FormatException {
      return const <String, String?>{};
    }
  }
}

/// 「图源设置」: one `BackupSourcePreferences` per Source that still has
/// configuration, keyed by Mihon's `source_<sourceId>`.
///
/// Imported settings for a source that was not installed are kept under
/// [kUnavailableMihonExtensionPackage]; they describe nothing the user can
/// use today, so they are skipped along with preference rows whose value has
/// no standard Mihon envelope (empty groups are not written either).
class _SourceSettingsExportSection {
  const _SourceSettingsExportSection(this.database);

  final MyComicDatabase database;

  Future<List<MihonBackupSourcePreferences>> load(
    MihonBackupExportOptions options,
  ) async {
    if (!options.includeSourceSettings) {
      return const <MihonBackupSourcePreferences>[];
    }
    final List<MangaSourcePreferenceRow> rows = await database
        .select(database.mangaSourcePreferences)
        .get();
    final Map<int, List<MangaSourcePreferenceRow>> bySource =
        <int, List<MangaSourcePreferenceRow>>{};
    for (final MangaSourcePreferenceRow row in rows) {
      if (row.extensionPackage == kUnavailableMihonExtensionPackage) continue;
      final int? sourceId = int.tryParse(row.sourceId);
      if (sourceId == null) continue;
      bySource
          .putIfAbsent(sourceId, () => <MangaSourcePreferenceRow>[])
          .add(row);
    }

    final List<int> sourceIds = bySource.keys.toList()..sort();
    final List<MihonBackupSourcePreferences> containers =
        <MihonBackupSourcePreferences>[];
    for (final int sourceId in sourceIds) {
      final List<MangaSourcePreferenceRow> prefRows = bySource[sourceId]!
        ..sort(
          (MangaSourcePreferenceRow a, MangaSourcePreferenceRow b) =>
              a.preferenceKey.compareTo(b.preferenceKey),
        );
      final List<MihonBackupPreference> preferences = <MihonBackupPreference>[];
      for (final MangaSourcePreferenceRow row in prefRows) {
        final String key = row.preferenceKey.trim();
        if (key.isEmpty) continue;
        // Same credential semantics as app settings (ticket 11): passwords,
        // tokens and keys only leave the device when explicitly requested.
        if (!options.includeSensitiveSettings &&
            PrefRedactionPolicy.isDeviceLocalOrCredential(key)) {
          continue;
        }
        final MihonBackupPreferenceValue? value = _jsonPreferenceValue(
          row.valueJson,
        );
        if (value == null) continue;
        preferences.add(MihonBackupPreference(key: key, value: value));
      }
      if (preferences.isEmpty) continue;
      containers.add(
        MihonBackupSourcePreferences(
          sourceKey: 'source_$sourceId',
          preferences: preferences,
        ),
      );
    }
    return containers;
  }

  /// Source preference rows store plain JSON (`MihonPreference.encodeValue`).
  static MihonBackupPreferenceValue? _jsonPreferenceValue(String raw) {
    try {
      return MihonBackupPreferenceTypes.fromDartValue(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }
}
