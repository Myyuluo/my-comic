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
