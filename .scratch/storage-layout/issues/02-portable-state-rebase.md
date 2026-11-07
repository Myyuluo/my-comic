# 02: Portable state 与 Content root 自动 rebase

**What to build:** 用户把程序目录连同 `userdata` 拷到另一台机器或另一个 Windows 用户后，Library、阅读进度、设置、扩展、自定义字体、WebView 数据、日志仍然可用。启动时如果记录里的 Content root 是旧用户的默认 `Documents\MyComic`，自动 rebase 到当前用户的默认路径；文件在则恢复，不在则显示 Missing。自定义 Content root 不可达时走现有的「数据位置未响应」逃生屏，不静默建空库。

**Blocked by:** 01

**Status:** resolved

- [x] 模拟把程序目录 + `userdata` 拷到新的 Windows 用户路径：Library、设置、扩展、字体、WebView 数据仍可见
- [x] 旧默认 `Documents\MyComic` 自动 rebase 到当前用户默认路径；文件存在则下载恢复，缺失则显示 Missing
- [x] 自定义 Content root 不可达时出现逃生屏（重试 / 本次用默认位置），不会静默派生空根
- [x] 可丢弃缓存不参与 portable 状态；`cache` 可以重建
- [x] 有自动化测试覆盖 rebase、Missing、逃生屏
