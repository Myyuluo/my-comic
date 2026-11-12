[根目录](../../CLAUDE.md) > [packages](../) > **my_comic_platform**

# my_comic_platform

## 模块职责

平台服务抽象模块：为 app 提供剪贴板、目录、设备信息、生命周期与权限的接口。纯 Flutter 依赖，无原生代码。

MyComic 只维护 Windows；旧版 TTS / PlatformIntegration / StoragePaths 抽象已删除（从未被实现或消费）。

## 入口与启动

- 库入口：`lib/my_comic_platform.dart`
- 无独立启动流程，由主应用注入具体实现。

## 对外接口

- `PlatformClipboardService` (`lib/src/services/platform_clipboard_service.dart`)
- `PlatformDeviceInfoService` (`lib/src/services/platform_device_info_service.dart`)
- `PlatformDirectoryService` (`lib/src/services/platform_directory_service.dart`)
- `PlatformLifecycleService` (`lib/src/services/platform_lifecycle_service.dart`)
- `PlatformPermissionService` (`lib/src/services/platform_permission_service.dart`)

## 关键依赖与配置

- 仅依赖 `flutter` SDK，零第三方依赖。
- 设计为纯抽象层，具体实现在主应用或平台 plugin 中。

## 测试与质量

- 无独立测试。纯抽象接口，通过主应用集成测试验证。

## 相关文件清单

- `lib/my_comic_platform.dart` -- 库入口
- `lib/src/services/platform_clipboard_service.dart` -- 剪贴板抽象
- `lib/src/services/platform_device_info_service.dart` -- 设备信息抽象
- `lib/src/services/platform_directory_service.dart` -- 目录抽象
- `lib/src/services/platform_lifecycle_service.dart` -- 生命周期抽象
- `lib/src/services/platform_permission_service.dart` -- 权限抽象

## 变更记录 (Changelog)

- 2026-05-23: 初始文档生成。
- 2026-11-12: 更新为 MyComic 当前实际导出的服务接口。
