# 02: 批量下载只服务在线漫画

**What to build:** 批量栏的「下载」按钮按选中内容决定可用态与目标：只选中本地卷时禁用；选中至少一部在线漫画时启用，混合选中时跳过本地卷并提示跳过数量；远端有章节的在线漫画先加入 Library，再按作品页「下载全部」的规则把全部未下载、未排队、未锁定的 Chapter 入队；远端无章节的整本漫画包仍按整本文件下载。单卡下载入口使用同一套判定。

**Blocked by:** 01（修复批量选择栏的失效动作）

**Status:** resolved

- [x] 只选中本地卷时下载按钮禁用。
- [x] 选中至少一部在线漫画时下载按钮启用；混合选中时跳过本地卷并提示跳过数量。
- [x] 在线漫画的全部未下载、未排队、未锁定 Chapter 入队，已下载 / 排队中 / 锁定章节按既有规则跳过。
- [x] 远端有章节的在线漫画先加入 Library 再入队全部章节；远端无章节整本包按整本下载。
- [x] 单卡下载与批量下载使用同一套启用与跳过规则。
- [x] 测试覆盖启用、禁用、跳过、远端章节漫画、远端整本包与非章节书分支。

## Comments

- 2026-11-06: Resolved on `integration/manga-ui-polish` (ticket merge `462551fc`; dual-axis review-fix merge `a0571b85`). Review follow-up further restricted download to online manga: remote SRT audiobooks and non-manga remote books no longer enable or participate.
