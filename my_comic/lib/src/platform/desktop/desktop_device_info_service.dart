import 'dart:io';

import 'package:my_comic_platform/my_comic_platform.dart';

class DesktopDeviceInfoService implements PlatformDeviceInfoService {
  @override
  Future<int?> get sdkVersion async => null;

  @override
  Future<String?> get deviceModel async => Platform.localHostname;

  @override
  Future<String?> get manufacturer async => null;
}
