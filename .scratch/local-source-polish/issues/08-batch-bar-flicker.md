# 08: 漫画页批量栏二次入场闪烁修复

**What to build:** 漫画书架页点击「选择」后，底部批量栏只出现一次，不再有第二次淡入/上滑；选择模式与批量栏内容不变。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 点击「选择」后批量栏只播放一次入场，不再二次出现
- [x] 退出选择时批量栏正常收起，无残留或重复
- [x] 已选数量、全选/反选与批量动作行为不变
- [x] 其它语言/平台分支的批量栏外观与动画不变
- [x] widget 测试逐帧断言批量栏只出现一次

## Answer

Implemented in `bd799819`, merged as `4a1b6229`. `FushiSpringReveal` 用稳定 keyed child 避免重建，批量栏入场只播放一次；逐帧回归测试覆盖。
