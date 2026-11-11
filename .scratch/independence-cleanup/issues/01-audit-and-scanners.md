# 01: 审计、扫描器与基线

**What to build:** 建立独立化清理的可重复验收基线：Fushi 引用扫描器、未使用 l10n key 扫描器、Windows analyze/test/build 基线，以及已知失败与 allowlist 记录。

**Blocked by:** None（can start immediately）

**Status:** ready-for-agent

- [ ] 创建 Fushi 引用扫描器：只读扫描受版本控制文件，按类别汇总（用户可见文案、代码标识符/import/路径、注释/文档、许可证/版权、third_party、历史文档）；支持 allowlist；输出文件级/行级报告。
- [ ] allowlist 覆盖 `LICENSE`、第三方 NOTICE/PATCHES/UPSTREAM、`UPSTREAM.md`、ADR、历史文档、README/About 的“基于 Fushi v3.0.0”署名，以及 git 历史。
- [ ] 创建未使用 l10n key 扫描器：读取 base JSON key 集合，扫描 `lib/`、`test/`、`integration_test/`，排除生成的 `strings.g.dart`；输出 key、是否引用、引用文件、功能前缀；支持动态访问白名单。
- [ ] 运行两个扫描器并保存基线报告；记录当前未引用 key 数量（审计时约 3,045）及主要前缀分布。
- [ ] 运行并记录 Windows 基线：`flutter analyze`、相关 `flutter test`、`flutter build windows --debug`；记录已知失败（manga-only schema、已删除源文件导致的静态扫描失败等）。
- [ ] 记录当前数据/身份基线：`my_comic.db`、Content root 默认 `<Documents>\MyComic`、更新源 `Myyuluo/my-comic`。
- [ ] 不修改产品代码；扫描器放在开发者工具位置，不进入 app 运行时。
- [ ] 在 ticket 或 spec 中写清扫描器复跑方式、allowlist 语义与报告位置。

**Notes:** 参考 [spec](../spec.md) 与 [ADR 0024](../../../docs/adr/0024-windows-only-independent-identity.md)。扫描器只读；是否把报告入库由实现者按项目惯例决定。
