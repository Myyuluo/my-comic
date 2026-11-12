// Method-channel names shared by the remaining MyComic features.
//
// Windows-only: the Android Java counterpart was removed with the platform
// trim. If you add a channel here, also register it in the Windows runner.

import 'package:flutter/services.dart';

abstract final class MyComicChannels {
  static const String _prefix = 'app.mycomic.reader';

  static const MethodChannel splash = MethodChannel('$_prefix/splash');
  static const MethodChannel update = MethodChannel('$_prefix/update');
  static const MethodChannel volumeKeys = MethodChannel('$_prefix/volume_keys');
  static const MethodChannel iconSwitch = MethodChannel('$_prefix/icon_switch');
  static const MethodChannel fonts = MethodChannel('$_prefix/fonts');

  /// 长按 app 图标的系统快捷方式（Windows 上 no-op，保留给共享门面）。
  static const MethodChannel appShortcuts =
      MethodChannel('$_prefix/app_shortcuts');
  static const MethodChannel clipboardImage =
      MethodChannel('$_prefix/clipboard_image');
  static const MethodChannel screenBrightness =
      MethodChannel('$_prefix/screen_brightness');
  static const MethodChannel selectionActions =
      MethodChannel('$_prefix/selection_actions');

  // TODO-1232 A3: render-backend experiment toggle (persist "disable Impeller"
  // so the next launch can force Skia).
  static const MethodChannel render = MethodChannel('$_prefix/render');
}
