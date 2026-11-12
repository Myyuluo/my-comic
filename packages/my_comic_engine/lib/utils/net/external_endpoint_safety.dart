/// 外部服务端点的传输安全判据（原 `media/torrent/torznab_client.dart`
/// 中的通用 helper；ticket 21/22 保留给 OPDS / Audiobookshelf / AI provider 复用）。
library;

bool isLoopbackProviderHost(String host) {
  final String normalized = host.toLowerCase();
  if (normalized == 'localhost' || normalized == '::1') return true;
  final List<String> parts = normalized.split('.');
  return parts.length == 4 && parts.first == '127';
}

/// HTTPS is always accepted. Plain HTTP requires loopback, or an explicit
/// opt-in suitable for a trusted LAN indexer configured by the user.
bool isSafeExternalProviderEndpoint(
  Uri endpoint, {
  bool allowInsecureHttp = false,
}) =>
    endpoint.scheme == 'https' ||
    (endpoint.scheme == 'http' &&
        (allowInsecureHttp || isLoopbackProviderHost(endpoint.host)));
