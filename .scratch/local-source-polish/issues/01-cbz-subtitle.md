# 01: CBZ 开关副标题文案

**What to build:** 设置 →「存储与下载」→「下载」分组里的「保存为CBZ压缩包」副标题显示「关闭后，下载的漫画将以文件夹+图片形式保存。」；简中/繁中为准确文案，其它 locale 同步更新。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 简中副标题为「关闭后，下载的漫画将以文件夹+图片形式保存。」
- [x] 繁中提供对应准确文案；英文及其它 locale 使用英文基线
- [x] i18n 排序 guard 与设置页 guard 通过
- [x] 开关标题、默认值（开启）与行为不变

## Answer

Implemented in `482b1e84`, merged as `bb8387a1`. 副标题为「关闭后，下载的漫画将以文件夹+图片形式保存。」，简中/繁中准确、其它 locale 英文基线，i18n guard 通过。
