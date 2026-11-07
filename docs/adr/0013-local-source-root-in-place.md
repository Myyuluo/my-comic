---
status: accepted
---

# 本地源根 localcomic 原地读取，按需扫描，不复制文件

用户需要把本地漫画放在一个可预期的目录里，my-comic 能读，Mihon 用户也熟悉这个目录习惯。我们决定把 Local source root 定为 Content root 下的 `localcomic`：结构为 `{manga}/{chapter}/`（章节文件夹内平铺页图，可带 `pages.json`）或 `{manga}/{chapter}.cbz`；只有用户点击「导入本地漫画」或「重建下载索引」时才扫描，不自动监视；原地读取、不复制；`cover.jpg` 可作封面；移出书架不删除文件，删除文件是单独动作；当前拖入 CBZ/文件夹会先复制到 `localcomic` 再登记，未来由「源」里的 Local source 入口取代拖入。作品身份按文件夹路径认，重命名/移动视为新作品，旧条目标记 Missing、不删；不往用户的 localcomic 写隐藏元数据。

**Considered Options**

- **复制进受管书库（旧 `fushi_books` 行为）**：删除/去重简单，但文件重复、用户找不到原文件。
- **任意路径原地引用**：灵活，但没有单一本地源根，Mihon 用户不熟悉。
- **写稳定 ID 元数据到 localcomic**：重命名可跟踪，但会修改用户目录。

**Consequences**

- Local source 内容不受应用管理；删除/清理需用户显式操作。
- 扫描是手动的；文件变化不会自动出现。
- `localcomic` 按 Mihon local-source layout 组织，但不承诺跨设备拷贝后 Mihon 直接读取。
- 未来在「源」里增加 Local source 入口后，移除拖入导入。

## Amendment 2026-11-08

「本地图源」入口现已落地：它固定出现在浏览页「图源」列表第一位，进入时自动扫描 Local source root（不再依赖「导入本地漫画」按钮），扫描结果以封面网格展示，只展示、不自动登记；用户在作品页显式 Add to Library 才把单部作品登记进 Library，点开某章阅读也会先静默登记。批量导入（浏览页「导入」子视图与设置里的「导入本地漫画」）已退役，只保留按单部作品登记的入口，供本地图源与 Rebuild download index 使用。书架拖入导入的行为同期收窄：拖入一部作品（文件夹或 `.cbz`）只复制并登记**该作品**；拖入 Local source root 本身时登记 root 下第一层的每部作品。原文中「拖入后扫描整个 root」的 root-wide sweep 已废止，以上述单部 / 第一层语义为准。原地读取、不复制、不写隐藏元数据等原决定不变；内置伪源的接入方式见 ADR 0014。原文「扫描是手动的」现在指扫描只由用户进入「本地图源」或运行 Rebuild download index 触发，仍然没有文件监视。
