/// 纯 Dart 的调试打印装配点，替代 `package:flutter/foundation.dart` 的
/// `debugPrint`，让 my_comic_core / my_comic_audio / my_comic_anki / my_comic_dictionary /
/// my_comic_engine 这些被无头服务端（`packages/my_comic_server`）消费的包不再拖进
/// `dart:ui`（`foundation.dart` 传递 import 它，`dart compile exe` 直接编不过）。
///
/// - Flutter app 在 `main()` 里装配 `myComicDebugPrint = debugPrint`，行为与从前
///   逐字节一致（同一节流、同一 console 通道）。
/// - 服务端 / 纯 Dart 测试不装配时走 [print]，与 Flutter 的默认实现同源
///   （`debugPrintThrottled` 底层就是 `print`）。
library;

/// 与 `debugPrint` 同签名。
typedef MyComicDebugPrint = void Function(String? message, {int? wrapWidth});

void _defaultDebugPrint(String? message, {int? wrapWidth}) {
  // ignore: avoid_print
  print(message);
}

/// 全局装配点。写入一次即可（Flutter app：`main()`；服务端：CLI 入口）。
MyComicDebugPrint myComicDebugPrint = _defaultDebugPrint;

/// 与 Flutter 的 `kDebugMode` 同语义（既非 product 也非 profile 构建）。
const bool myComicDebugMode = !bool.fromEnvironment('dart.vm.product') &&
    !bool.fromEnvironment('dart.vm.profile');
