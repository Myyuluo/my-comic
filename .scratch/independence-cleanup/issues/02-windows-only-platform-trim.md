# 02: Windows-only 平台裁剪

**What to build:** 把项目收窄为 Windows-only：删除 Android/iOS/macOS/Linux/Web 平台目录、打包配置、平台专用 Dart 分支/依赖/测试和对应 CI，只保留 Windows runner、Inno Setup、JVM sidecar 与 Windows 构建链。

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] 删除 `android/`、`ios/`、`macos/`、`linux/`、`web/` 平台目录与 apple 共享平台代码。
- [ ] 删除仅移动端/非 Windows 使用的依赖、条件分支、platform channel 常量和测试；保留 Windows 需要的分支，并把剩余平台判断简化为 Windows-only。
- [ ] 删除 Android release、macOS/iOS desktop release、multiplatform 非 Windows job、linux-server job；保留 Windows analyze/test/golden/debug/release/installer workflow。
- [ ] 更新构建脚本、CI 和产物路径中的平台枚举；不删除 Windows 安装器。
- [ ] 保留 JVM sidecar、Extension runtime、Windows WebView2 与 Windows 原生通道。
- [ ] 不删除 `fushi_server` 或非漫画 workspace 包（由 03 处理）。
- [ ] 验证：`flutter analyze`、相关 `flutter test`、`flutter build windows --debug` 通过；CI 只枚举 Windows。

**Notes:** 参考 [spec](../spec.md) 与 [ADR 0024](../../../docs/adr/0024-windows-only-independent-identity.md)。平台删除后，相关 README/文档中的平台表由 11 统一重写。
