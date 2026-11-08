---
status: accepted
---

# 内容根与程序状态根分离：内容留在 Documents，程序状态跟着 exe 走

my-comic 需要同时满足两件事：用户能在资源管理器里直接找到下载的在线漫画、本地漫画和备份，并且卸载/更新不会误删这些文件；同时把程序目录连同数据库、设置、扩展和缓存拷到另一台机器就能继续用。我们决定把存储拆成两个根：

- **Content root（内容根）**：用户可见的漫画内容——Download library、Backup directory、Local source root。默认 `<Documents>\MyComic`，可在设置中切换；卸载和更新都不触碰它。切换内容根只创建新的空目录，不搬移文件；旧路径下的下载变为 Missing，直到用户搬移文件并运行 Rebuild download index。
- **Program state root（程序状态根）**：exe 同级的 `userdata`，下分 `state`（数据库、设置、扩展、字体、WebView 数据、日志、更新包）与 `cache`（可丢弃缓存）。更新保留、卸载删除。安装目录不可写时回退到 `%LOCALAPPDATA%\MyComic\userdata`，并明确提示便携状态不随安装目录走。

安装器保留标准「选择安装位置」页和可写性预检，删除自定义「数据存储位置」页与 `data_root.bootstrap`。未来的 Portable build（无安装器 ZIP）不在 v1 范围内；当前的 Portable state 靠「程序目录 + `userdata`」实现。

**Considered Options**

- **全部放 exe 同级**：便携性最好，但卸载/更新会删掉用户的下载、本地漫画和备份，不可接受。
- **全部放 Documents**：卸载安全，但程序状态不能随程序走，数据库还会落在可能被 OneDrive 同步的目录。
- **保留旧 documents/support 两棵树**：仍然是两个根，但按内容类型而不是生命周期拆，用户无法预期「哪些会随卸载消失」。

**Consequences**

- 卸载删除 `userdata`：书库记录、阅读进度、设置、扩展会丢失；Content root 的文件保留。
- 更新原地覆盖安装；`userdata` 不在安装清单里，升级保留。需要安装脚本和打包流程的守卫测试，防止未来把 `userdata` 写进 `[InstallDelete]` 或 `[Files]`。
- 便携拷贝 = 程序目录 + `userdata`；Content root 不随包走，缺失的下载显示 Missing。
- 切换内容根不搬文件，也不从旧路径读取；恢复靠 Rebuild download index。
- 安装目录必须可写才能获得便携状态；否则回退系统目录并提示。
- UI 只允许必要的文案、只读路径行、「重建下载索引」入口、`downloads` / `localcomic` / `autobackup` 三个文件夹的打开入口（ticket 08 明确要求），以及「导入本地漫画」扫描入口（spec 故事 26）；复用现有组件与主题；不改变设计/美术（ADR 0008）。

## Amendment 2026-11-08

设置页的存储入口已收敛为一个：「存储位置」（即 Content root）整行只读，行尾提供「变更文件夹」与「打开文件夹」；「变更文件夹」沿用原切换语义，「打开文件夹」在目录不存在时先创建再打开。原先在「存储与下载」里重复列出的 `downloads` / `localcomic` / `autobackup` 三个文件夹入口已移除，SRS 备份页上的同名入口也一并消失。备份分组（导入 / 导出 Mihon 备份）从「系统与关于」搬入「存储与下载」，分组顺序为数据存储位置 → 下载 → 备份 → 下载索引。

原文 **Consequences** 中「UI 只允许……三个文件夹的打开入口……以及『导入本地漫画』扫描入口」一条由本修订取代：三个文件夹入口与「导入本地漫画」入口都不再存在；本地漫画改由图源列表里的「本地图源」按单部作品登记（见 ADR 0013 修订与 ADR 0014）。

## Amendment 2026-11-08（local-source-polish）

Content root 的三个子目录为 `downloads` / `autobackup` / `local`：本地源根目录名由 `localcomic` 改为 `local`，默认路径为 `<Documents>\MyComic\local`；旧 `localcomic` 不再扫描、不迁移、不删除。原文与上一修订中出现的 `localcomic` 均按 `local` 理解；本地源根的完整修订见 ADR 0013。

本地漫画的登记入口除作品页的单部 Add to Library 外，也支持本地图源页选择模式下的**批量** Add to Library（见 ADR 0013 的 2026-11-08「批量加入书架」修订）；上一修订中「按单部作品登记」的描述按「单部或批量显式动作」理解。
