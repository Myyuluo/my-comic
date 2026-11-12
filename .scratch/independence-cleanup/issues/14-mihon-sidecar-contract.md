# 14: M-Extension-Server sidecar 启动回归

**What to build:** 修复安装 Mihon 扩展时弹出的 `MihonRuntimeException(START_TIMEOUT): M-Extension-Server did not report a listening port`，让桌面 sidecar 正常启动并上报端口。

**Blocked by:** None（post-review regression）

**Status:** resolved

- [x] 用真实 runtime 复现：`java -jar m-extension-server.jar 0 <data>` + `MYCOMIC_MIHON_TOKEN` → exit 1，`FUSHI_MIHON_TOKEN is required`；改用 `FUSHI_MIHON_TOKEN` → 打印 `FUSHI_MIHON_READY port=12484` 并保持运行。
- [x] 宿主同时发送 `MYCOMIC_MIHON_TOKEN` / `FUSHI_MIHON_TOKEN` 与 `MYCOMIC_MIHON_PROXY_POLICY_PORT` / `FUSHI_MIHON_PROXY_POLICY_PORT`。
- [x] 宿主同时接受 `MYCOMIC_MIHON_READY port=` 与 `FUSHI_MIHON_READY port=`。
- [x] 新增 sidecar 契约单元测试与真实 jar 集成测试；修复后集成测试全部通过。
- [x] 在 Fushi 引用 allowlist 中把 `FUSHI_MIHON_*` 登记为冻结的预编译二进制契约，并在 ADR 0024 记录。
- [x] 重新构建 Release 并验证扩展安装不再报 START_TIMEOUT。

## Root cause

ticket 10 的全量改名把宿主侧 sidecar 环境变量与 ready 前缀从 `FUSHI_MIHON_*` / `FUSHI_MIHON_READY` 改成了 `MYCOMIC_MIHON_*` / `MYCOMIC_MIHON_READY`，但随包的 `m-extension-server.jar` 是固定版本的预编译二进制，仍只读取旧名字。sidecar 启动时直接抛 `IllegalStateException: FUSHI_MIHON_TOKEN is required`，永远不会打印 ready 行，宿主在 20 秒后报 `START_TIMEOUT`。代理策略端口也因为同样的原因被 sidecar 忽略。

## Fix

- 宿主 `buildSidecarEnvironment` 同时发送新旧四组环境变量；预编译 jar 读取旧名字，新名字留给未来重建的 jar。
- `parseReadyPort` 接受两种 ready 前缀。
- 这些旧名字是冻结的二进制契约，不是用户可见品牌；允许 list 规则限定在 `desktop_mihon_runtime.dart` 和对应测试的 `FUSHI_MIHON_*` 行。

## Verification

- 真实 runtime 复现：旧宿主行为 exit 1 / 新宿主行为启动并上报端口。
- `flutter test --no-pub test/media/manga/desktop_mihon_runtime_integration_test.dart`（`MYCOMIC_TEST_MIHON_RESOURCES` 指向 Release runtime）修复后 3/3 通过。
- `flutter test --no-pub test/media/manga/desktop_mihon_sidecar_contract_test.dart` 2/2 通过。
- `dart tool/audit/fushi_references.dart --fail-on-violations` 通过（旧 sidecar 名字已 allowlist）。
- 重新构建 Release 后启动应用、安装扩展不再出现 START_TIMEOUT。
