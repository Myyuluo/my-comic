# 06: 领域文档与 ADR 同步

**What to build:** 更新领域文档，记录本次导入体验修复的语义：Missing source（缺失来源）、按 sourceId 的运行时来源回退、封面远程回退，以及「不做身份迁移」的边界。

**Blocked by:** 01（导入完成弹窗重设计）、02（导入作品封面远程回退）、03（已安装扩展的导入作品恢复可读）、04（缺失来源的名称与中文提示）、05（导入后标签页签即时刷新）

**Status:** resolved

- [x] GLOSSARY 新增 Missing source（缺失来源）：被 Library 作品引用但对应 Source 未安装/未启用；作品保留、封面与已下载章节可用、阅读需安装扩展；运行时按 sourceId 解析且不改变条目身份。
- [x] ADR 0019 增补运行时来源回退、封面远程回退与缺失来源文案，并明确不做 `extensionPackage` / `bookKey` / `uid` 迁移。
- [x] 记录本次弹窗与封面 UI 改动是在 ADR 0008 下由用户逐项批准的，复用 Fushi 组件与主题。
- [x] 明确「来源未安装」与 `mihon.unavailable` 的区别：后者是内部占位值，不出现在用户文案中。
- [x] 文档只描述用户可见行为与领域语义，不写会过时的实现细节。
- [x] 不修改代码、测试或 spec；不提交真实 `.tachibk`。

## Answer

本次提交 `38208405 docs: sync domain docs for missing sources and import fallbacks` 完成三处文档同步，仅改动 Markdown，未触碰代码、测试或 spec，也未提交任何 `.tachibk`。

**GLOSSARY.md：Missing source（缺失来源）**

新增条目定义：Library 中的 Manga 引用了一个未安装或未启用的 Source 时的状态。该 Manga 保留在 Library，备份带来的远程封面与本机已有封面仍可显示，已下载 Chapter 仍可离线阅读；刷新章节、加载在线页面与下载需先安装并启用对应 Extension。用户界面统一用「来源未安装」表达，已知名称时显示「来源未安装：<名称>」。运行时按数字 `sourceId` 解析到已安装的 Source，不改写条目来源身份，因此 Reading progress、Chapter 状态、History、Tag 与下载映射均无需迁移；同一数字 `sourceId` 命中多个已启用 Source 时按缺失处理。`_Avoid_` 一行明确 `mihon.unavailable` 是内部占位值、不是领域术语。

**ADR 0019 增补（Amendment 2026-11-10, manga-backup-import-ux）**

- 运行时来源回退：先精确匹配 `(extensionPackage, sourceId)`，未命中再按数字 `sourceId` 匹配已启用 Source；刷新章节、加载页面、下载、取封面、解析来源名称共用该规则；多包命中同一 `sourceId` 视为歧义并按缺失降级，回退只发生在运行时、不回写条目。
- 不做身份迁移：不改 `extensionPackage`、不重算 `bookKey`、不改写 `uid` / History source identity / 下载 manifest；安装 Extension 后 Reading progress、Chapter 状态、History、Tag 与下载映射保持原样。重复检测按 `(数字 sourceId, series key)` 命中既有占位条目。
- 封面远程回退：按「显式本地封面 → 常规本地封面文件 → 备份 `series.coverUrl` → 占位封面」解析；远程 URL 交由现有 HTTP 图片缓存懒加载，不写入最近可用本地封面缓存，导入阶段不下载封面，失败时回退占位封面。
- 缺失来源文案：统一「来源未安装」，已知名称显示「来源未安装：<名称>」；导入完成报告用 warning notice 列出名称并提示安装扩展；作品页说明只展示本机已有章节；章节打开/下载失败提示「来源未安装，请先安装对应扩展后重试」；不自动安装、不跳转扩展商店、不隐藏或删除 Manga。
- 内部占位值边界：`mihon.unavailable` 仅为导入时写入的内部占位标识，不出现在用户文案；备份导出跳过这类占位来源的图源设置。
- Consequences：安装启用扩展后刷新即可阅读、无需重新导入或重启；歧义 `sourceId` 保持不可解析而非打开错误站点；远程封面 URL 失效时显示占位封面；来源身份保持导入时写入值，将来改写需单独决策并迁移；旧备份缺名称时只显示「来源未安装」。

**ADR 0008 增补**

记载 manga-backup-import-ux 的导入完成 / 创建备份结果弹窗重排与导入作品封面远程回退，是用户 2026-11-10 逐项明确批准的 UI 改动；实现只复用 Fushi v3.0.0 的弹窗、卡片、notice、hero icon 与 spacing tokens，封面沿用现有图片缓存与占位组件，Fushi 的 shell、组件、主题与布局均未替换或简化。
