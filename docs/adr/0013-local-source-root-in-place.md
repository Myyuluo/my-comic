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

## Amendment 2026-11-08（local-source-polish）

Local source root 的目录名由 `localcomic` 改为 Content root 下的 `local`；旧 `localcomic` 不再扫描、不迁移、不搬移、不删除，旧登记行变为 Missing 是接受的代价。扫描的只读约束调整为「只允许补写缺失的 `cover.jpg`」：作品根目录没有 `cover.jpg/jpeg/png` 时，可从第一页生成一张可见的 `cover.jpg`；已有封面绝不覆盖，仍不写隐藏 ID、不复制或移动页文件。已登记作品的 `coverPath` 在生成后同步指向该封面，使书架与作品页可见。封面是用户 `local` 目录内的普通可见文件，不是隐藏元数据。

## Amendment 2026-11-08（local-source-polish，批量加入书架）

本地图源现在也支持**批量** Add to Library：本地图源页右上「选择」进入选择模式后，可把当前页签 + 搜索可见的选中作品一次性登记进 Library（只登记未入架的作品；`book_tombstones` 里主动移出的作品算未入架，显式加入会重新登记）。上一修订「只保留按单部作品登记的入口」的描述因此扩展为「单部或批量显式动作」：作品页的单部加入与本地图源页的批量加入都走同一条 `LocalSourceLibrary.registerScannedManga` 写入路径。扫描仍然只展示、不自动登记——批量加入只在用户显式进入选择模式并点击「加入书架」时发生；原文与上一修订中的「按单部作品登记」按此理解。

## Amendment 2026-11-10（manga-ux-backup-batch，移出书架可显式删除原作）

「移出书架」仍默认保留 Local source 原作文件；但统一删除弹窗新增的「同时删除本地文件」允许用户显式勾选后，在删除 Library 记录前删除 `local` root 中的原作文件夹或文件。文件删除失败时作品保留在 Library 并报告失败；文件本来就不存在视为已删除。独立的「删除本地文件」动作保持不变。这取代原文「移出书架不删除文件」中「绝不能在移出流程内删文件」的绝对表述，但默认安全行为不变。
