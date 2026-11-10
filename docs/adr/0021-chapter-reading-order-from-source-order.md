---
status: accepted
---

# 章节阅读顺序以 sourceOrder 为准，与显示顺序解耦

`.tachibk` 导入的章节数组顺序不是可靠的阅读顺序：作品页按「最新在前」显示，阅读器又曾假设存储数组就是新→旧，导致读完第 1 话被当成最后一话。我们决定把规范的 Chapter reading order 显式化：

- 导入时持久化 Mihon `BackupChapter.sourceOrder`（proto field 10）。它表示 Chapter 在源列表里的位置，`0` = 最新一话。
- 阅读顺序是独立的升序列表（第 1 话 → 第 N 话），按 `sourceOrder` 降序构造；缺失时回退 Chapter 号升序、再回退上传时间升序；仍无法区分时沿用源的新→旧输入约定。
- 阅读器只在该阅读顺序列表上取 `index ± 1` 切换上一话 / 下一话，只有真正最后一话提示「已经是最新一章」；换章不依赖导入数组顺序或作品页当前显示顺序。
- 作品页默认「最新在前」显示阅读顺序的反转；切换到「第一话在前」时显示阅读顺序本身。显示排序不改变 Chapter 身份或阅读顺序。
- 在线源在刷新时按源列表下标补 `sourceOrder`（`0` = 最新），使在线源与导入作品共用同一换章规则，在线源现有行为不变。
- 已有导入作品不猜测旧数据方向；重新导入同一 `.tachibk` 即补齐 `sourceOrder`，导入幂等、不重复创建作品。
- 备份导出写回已持久化的 `sourceOrder`，my-comic 往返保留阅读顺序。

**Mihon 参考**

Mihon v0.21.3 的 `BackupChapter.sourceOrder` 是 proto field 10，恢复时写回数据库。`ReaderViewModel` 用 `getChapterSort(manga, sortDescending = false)` 构造升序阅读列表，并以 `index ± 1` 切换上一话 / 下一话；默认 source order 下 `sourceOrder` `0` 为最新，阅读顺序即 `sourceOrder` 降序。

**Considered Options**

- **信任导入的章节数组顺序**：实现最简单，但数组顺序与「最新在前」约定不一致，换章方向错误，正是本次要修的问题。
- **只按 Chapter 号 / 上传时间排序**：常规章节够用，但自定义标题、无编号 Chapter 的真实源顺序会丢失。
- **导入时把数组重排为「最新在前」**：能让旧阅读器工作，但改写数据且仍需猜测源顺序；`sourceOrder` 是 Mihon 已提供的真实依据。
- **自动猜测已有导入作品的方向**：避免重新导入，但方向猜测不可靠，可能把已有作品弄反；明确要求重新导入一次更安全。

**Consequences**

- 导入的 Chapter 现在携带 `sourceOrder`；旧数据可能缺失，阅读顺序回退 Chapter 号 / 上传时间。
- 作品页显示排序与阅读器换章共用同一份升序阅读顺序推导。
- 旧导入作品在重新导入前仍按回退顺序换章；重新导入后补齐，无需手工修数据。
- `sourceOrder` 是备份兼容字段，不影响 History 的导入与导出。
