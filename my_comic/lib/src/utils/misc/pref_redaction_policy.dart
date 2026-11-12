/// 「一条 `preferences` key 能不能离开本设备」的唯一真相源。
///
/// Ticket 04 删除云同步 / 互联后，原 `SyncRepository.deviceLocalPrefKeys` 清单随
/// 之消失；Mihon 备份导入/导出仍需要同一套凭据剔除语义，故把判定收敛到本文件。
/// 设备本地判定改为「同步 / 配对家族前缀 + 明确点名」，宁可多剔除也不让凭据出境。
abstract final class PrefRedactionPolicy {
  /// 形状兜底：key 含这些子串即视为凭据，不限前缀。
  static const List<String> credentialSubstrings = <String>[
    'password',
    'token',
    'secret',
    'private_key',
    'credential',
    'api_key',
  ];

  /// 整族按行 id 展开、无法逐个列举的凭据 key。
  static const List<String> sensitiveKeyPrefixes = <String>[
    'media_source_secret_',
  ];

  /// 名字看不出是凭据、但值里裹着凭据 / 设备本地事实的 key。
  static const Set<String> sensitiveKeys = <String>{
    'qb_connection_config',
    'network_proxy_username',
    'video_anidb_username',
    'video_anidb_password',
    'jimaku_api_key',
    'video_subtitle_subdl_api_key',
    'manga_cloud_ocr_api_key',
    'video_scraper_tmdb_api_key',
    'video_metadata_fanart_api_key',
    'video_metadata_bangumi_token',
    'video_metadata_douban_authorized_token',
    'media_tracking_bangumi_access_token',
    'video_metadata_douban_authorized_endpoint',
    'video_resource_torznab_config',
    'video_subtitle_opensubtitles_config',
    'ai_providers',
    'discovery_opds_servers',
    'discovery_alist_sites',
    'discovery_audiobookshelf_servers',
    'tts_voice_presets',
    'sync_deletion_tombstones_baseline_ms',
    'sync_video_metadata_since_ms',
    'srs_mining_target_install_default',
  };

  /// 设备本地家族前缀：云同步 / 互联 / 配对产生的键描述的是本机状态。
  static const List<String> deviceLocalPrefixes = <String>[
    'sync_',
    'interconnect_',
    'my_comic_client_',
    'hidden_remote_books',
    'device_id',
  ];

  /// key 是否属于「设备本地 / 凭据」，即备份出口必须剔除的一类。
  static bool isDeviceLocalOrCredential(String key) {
    final String lower = key.toLowerCase();
    for (final String prefix in deviceLocalPrefixes) {
      if (lower.startsWith(prefix)) return true;
    }
    if (sensitiveKeys.contains(key)) return true;
    for (final String prefix in sensitiveKeyPrefixes) {
      if (lower.startsWith(prefix)) return true;
    }
    for (final String substring in credentialSubstrings) {
      if (lower.contains(substring)) return true;
    }
    return false;
  }
}
