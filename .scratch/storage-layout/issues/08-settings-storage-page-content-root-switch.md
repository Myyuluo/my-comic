# 08: Settings storage page + Content root switch

**What to build:** 设置 → 存储与下载显示 `漫画数据位置`（Content root）与 `程序数据位置`（Program state root，只读），可以打开 `downloads`、`localcomic`、`autobackup`。用户切换 Content root 时，应用只在新位置创建三个空文件夹，不移动/复制旧文件；旧路径下的下载和本地漫画变为 Missing，不再从旧路径读取；不弹「请迁移后重建」的提示。UI 只增加必要文案和入口，复用现有组件、布局、主题、图标，不改变设计/美术。

**Blocked by:** 04, 06

**Status:** resolved

- [x] 设置页显示 `漫画数据位置` 与 `程序数据位置`（只读），以及三个文件夹的打开入口
- [x] 切换 Content root 只创建 `downloads`/`autobackup`/`localcomic` 空文件夹，不移动/复制旧文件
- [x] 切换后旧路径下的下载/本地漫画显示 Missing，且应用不再读取旧路径
- [x] 不出现迁移/重建弹窗提示
- [x] UI 复用现有设置组件、布局、主题、图标，没有视觉设计/美术改动
- [x] 有设置页/widget 测试覆盖文案、可见性、切换行为
