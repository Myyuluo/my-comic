---
status: accepted
---

# 扩展兼容以 Fushi v3.0.0 的行为为基准

用户要求支持 Mihon 扩展，而复制 Fushi 的扩展子系统只能保证与 Fushi 行为一致，不能保证超出 Fushi 的兼容范围。我们决定把验收标准定为：Fushi v3.0.0 能安装/运行的 Extension，my-comic 也必须能；用用户常用的扩展列表和 Keiyoushi 抽样对照测试，Fushi 本身失败的扩展不计为 my-comic 的缺口。

**Consequences**

- 不承诺 Keiyoushi 全部扩展都可搜索/阅读。
- 如果未来要求超出 Fushi 的兼容性，需要单独投入 Android 兼容层维护，不属于当前范围。
