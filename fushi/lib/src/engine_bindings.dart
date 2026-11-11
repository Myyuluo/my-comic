/// Flutter app 对 `fushi_engine`（以及 fushi_core / fushi_audio）平台装配点的
/// 一次性接线。
///
/// 引擎包不依赖 Flutter，它需要的日志、数据根、图片缓存失效、
/// 调试打印全靠宿主在进程入口装配。与 `installAsrHostBindings()` 同一范式、同一
/// 调用位置（`main()`，不放 `AppModel.initialise()`：弹窗词典与悬浮词典两个入口
/// 绕开 initialise）。`flutter_test_config.dart` 也调它，保证测试里的引擎代码拿到
/// 与从前逐字节一致的行为（`AppPaths` 路径、`ErrorLogService` 记录）。
///
/// 幂等：重复调用只是重复赋同一批值。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show RootIsolateToken;
import 'package:fushi/src/utils/cover_image.dart';

import 'package:fushi/src/models/store_compliance.dart';

import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/foundation/engine_platform_hooks.dart';


/// `AppPaths` 静态便捷层 → 引擎 [EnginePaths]。三个引擎根逐一委派到新的
/// Content root / Program state `state/` / `cache/`，子目录名契约留在引擎基类。
class AppPathsEngineBridge extends EnginePaths {
  const AppPathsEngineBridge();

  @override
  Future<Directory> documentsRootDirectory() => AppPaths.contentRootDirectory();

  @override
  Future<Directory> supportRootDirectory() => AppPaths.stateRootDirectory();

  @override
  Future<Directory> tempRootDirectory() => AppPaths.cacheRootDirectory();

  /// iOS：file_picker 把选中文件搬进 `NSTemporaryDirectory()`（容器 `tmp/`，iOS
  /// 把 `TMPDIR` 设成它，即 [Directory.systemTemp]）。注意它**不是**
  /// [tempRootDirectory]——path_provider 在 iOS 上给的是 `Library/Caches`。
  @override
  Future<List<Directory>> pickerImportCopyDirectories() async =>
      Platform.isIOS ? <Directory>[Directory.systemTemp] : const <Directory>[];
}

/// 写后驱逐：与 `MediaCoverService` 历来的收口同一份双键 evict（裸 FileImage +
/// resizedFileImage），只动这一条路径的条目，不清整表——刮削几百张封面时整表
/// clear 会把书架滚动变成重解码风暴。
Future<void> _evictImageCacheForFile(File file) =>
    evictLocalCoverCache(file.path);

/// 删前释放：与 develop 上 `VideoStorage._evictImageCacheForFile` 逐字同义——
/// 整表 clear 是「锁释放提示」（Windows 上解码器持有的句柄让 delete 失败），
/// 纯存储测试没有 painting binding 时吞掉，不能挡住真正的删除。
Future<void> _releaseImageCacheBeforeDelete(File file) async {
  try {
    final ImageCache imageCache = PaintingBinding.instance.imageCache;
    imageCache.clearLiveImages();
    imageCache.clear();
    await FileImage(file).evict();
  } catch (_) {
    // 见上：缺 binding 只意味着没有缓存可放，不影响删除。
  }
}

void installEngineHostBindings() {
  fushiDebugPrint = debugPrint;
  engineLog = ErrorLogService.instance;
  enginePaths = const AppPathsEngineBridge();
  // 发现来源 chip 的资料源名走 i18n 出口（引擎默认是不翻译的品牌名）。
  evictImageCacheForFile = _evictImageCacheForFile;
  releaseImageCacheBeforeDelete = _releaseImageCacheBeforeDelete;
}
