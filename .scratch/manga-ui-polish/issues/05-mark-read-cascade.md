# 05: 标记 / 取消已读完级联章节与卷

**What to build:** 在线漫画点「标记为已读完」时，本书所有 Chapter 变为已读；点「取消已读完」时，本书所有 Chapter 的已读状态被清空，但保留每章上次读到的页码与当前章位置。本地卷没有 Chapter，标记 / 取消只切换这一卷的书级完成标记，不修改阅读位置或页进度。书架卡片完成视觉、「阅读状态」筛选与作品页章节列表立即同步。

**Blocked by:** 03（重排漫画卡长按菜单）

**Status:** resolved

- [x] 在线漫画「标记为已读完」后，本书所有 Chapter 的已读时刻被写入。
- [x] 在线漫画「取消已读完」后，本书所有 Chapter 的已读时刻被清空。
- [x] 取消后各章上次页码与当前章位置保持不变，下次仍从原页继续。
- [x] 本地卷标记 / 取消只切换书级完成标记，阅读位置和页进度不变。
- [x] 书架卡片完成视觉与「阅读状态」筛选立即更新，作品页章节列表同步。
- [x] 测试覆盖在线漫画、本地卷、取消后恢复位置三条路径。

## Comments

- 2026-11-06: Resolved on `integration/manga-ui-polish` (ticket merge `a5c610a8`; dual-axis review-fix merge `a0571b85`). Review follow-up added `preserveUpdatedAt` so mark-all also keeps the effective current chapter.
