import 'package:flutter/foundation.dart';

import 'package:fushi_engine/utils/net/app_proxy.dart';

/// Install outbound factories in every app entry point after preferences load.
///
/// Await system proxy discovery before exposing services: synchronous HTTP
/// factories otherwise see an empty proxy cache on their first request.
Future<void> installAppNetworkBindings({
  @visibleForTesting Future<void> Function() primeProxy = primeAppProxy,
}) async {
  await primeProxy();
}
