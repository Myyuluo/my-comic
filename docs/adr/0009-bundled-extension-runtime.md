---
status: accepted
---

# Extension runtime 随应用分发，只启动随包副本

my-comic 需要在不要求用户安装 Java 或运行本地服务器的前提下执行 Mihon Extension。我们决定把 Extension runtime 作为 Bundled extension runtime 随应用构建和安装包分发；应用只启动随包副本，不做 PATH、系统 Java、外部 Fushi 安装目录或其他 fallback 的运行时发现。本地 Windows 的 build-and-run 流程负责把官方 Fushi v3.0.0 的 runtime 放入构建产物；直接 `flutter build windows` 不包含这一步。官方 runtime 不可用时，可由冻结的 vendored 源码以 CI 同一命令重建；无论来源，JAR 必须匹配固定的官方 SHA256。缺失或来源不匹配时必须让构建或启动明确失败，而不是降级到另一份运行时。

**Consequences**

- 安装包体积包含 JVM 与 M-Extension-Server，不能靠复用系统 Java 省体积。
- 打包缺口会以 `RUNTIME_MISSING` 明确暴露；CI 的 runtime 校验与本地构建脚本共同保证随包副本存在且哈希匹配。
- 本地构建脚本把官方哈希钉死；源码重建是可复现的兜底，不能替换成任意 runtime。
- 未来若要走「复用系统运行时」或「运行时自动下载」，需要先重新评估这条 ADR。
- 扩展行为仍以 Fushi v3.0.0 为兼容基准（ADR-0006），runtime 来源锁定在冻结快照（ADR-0003）。
