import 'dart:io' show Platform;

import 'package:my_comic_platform/my_comic_platform.dart';

import 'package:my_comic/src/platform/desktop/desktop_directory_service.dart';
import 'package:my_comic/src/platform/desktop/desktop_lifecycle_service.dart';
import 'package:my_comic/src/platform/desktop/desktop_clipboard_service.dart';
import 'package:my_comic/src/platform/desktop/desktop_permission_service.dart';
import 'package:my_comic/src/platform/desktop/desktop_device_info_service.dart';

/// Holds all platform-specific service implementations.
///
/// Created once in `main()` before `runApp()` and passed to [AppModel] as a
/// constructor parameter. Ticket 04 removed the Anki backend factories; only
/// the OS-level services and platform flags remain.
class PlatformServices {
  final PlatformDirectoryService directory;
  final PlatformLifecycleService lifecycle;
  final PlatformClipboardService clipboard;
  final PlatformPermissionService permission;
  final PlatformDeviceInfoService deviceInfo;

  /// 本进程跑在 Windows 上吗。
  final bool isWindows;

  /// 本进程跑在桌面端吗。
  final bool isDesktop;

  /// 本进程跑在 iOS 上吗。
  final bool isIOS;

  /// 本进程跑在 Android 上吗。
  final bool isAndroid;

  PlatformServices({
    required this.directory,
    required this.lifecycle,
    required this.clipboard,
    required this.permission,
    required this.deviceInfo,
    bool? isWindows,
    bool? isDesktop,
    bool? isIOS,
    bool? isAndroid,
  })  : isWindows = isWindows ?? Platform.isWindows,
        isDesktop = isDesktop ??
            (Platform.isWindows || Platform.isMacOS || Platform.isLinux),
        isIOS = isIOS ?? Platform.isIOS,
        isAndroid = isAndroid ?? Platform.isAndroid;

  /// Cross-service wiring that requires async initialisation.
  Future<void> init() async {}

  /// Constructs the correct service bundle for the current platform.
  ///
  /// my-comic is Windows-only: the desktop service bundle is the only one.
  factory PlatformServices.forCurrentPlatform() {
    return PlatformServices(
      directory: DesktopDirectoryService(),
      lifecycle: DesktopLifecycleService(),
      clipboard: DesktopClipboardService(),
      permission: DesktopPermissionService(),
      deviceInfo: DesktopDeviceInfoService(),
    );
  }
}
