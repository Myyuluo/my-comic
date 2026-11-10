# 01: 导入完成弹窗重设计

**What to build:** `.tachibk` 导入成功后的报告弹窗使用 Fushi 组件重新排版：hero 图标 + 标题/副标题，正文按「书架与阅读」「设置与来源」两张卡片分组，缺失来源用 warning notice 展示；补足左右内边距，隐藏零值诊断行，不新增跳转按钮。创建备份结果弹窗同步补足 padding。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 导入完成弹窗正文有正常左右内边距，文字不再紧贴弹窗左边缘。
- [x] 顶部显示 hero 图标、标题「备份导入完成」与显示处理总量的副标题。
- [x] 「书架与阅读」卡片包含书架新增/合并/跳过/失败、分类新建/已存在、阅读进度、History；有数据时包含未入架 History 与追踪。
- [x] 「设置与来源」卡片包含应用设置、来源偏好与扩展仓库；有数据时显示对应计数与诊断。
- [x] 主计数始终显示；仅用于诊断的零值行隐藏。
- [x] 缺失来源使用 warning 色 notice，列出来源名称并提示安装对应扩展；notice 不提供「打开扩展商店」或任何跳转按钮。
- [x] 没有缺失来源时不显示 warning notice。
- [x] 窄窗口或高缩放下弹窗可滚动且不溢出。
- [x] 创建备份结果弹窗补足 body padding，不再贴左。
- [x] 新增页面级 widget 测试，覆盖 padding、分组、零值隐藏、缺失来源 notice 与无按钮。

## Answer

Implemented in `d56fa76b`, merged as `e8c656d2`. 导入完成弹窗改为 Fushi 弹窗（`FushiDialogFrame` + `FushiModalSheetFrame`）：hero 图标「备份导入完成」、副标题显示已处理总量，正文补齐左右内边距；结果按「书架与阅读」「设置与来源」两张卡片分组，主计数始终显示、仅诊断的零值行隐藏；缺失来源用 warning notice 列出名称并提示安装对应扩展，不提供任何跳转按钮；单一滚动视口适配窄窗口与高缩放。创建备份结果弹窗同步补足 body/footer padding。新增 `mihon_backup_import_report_dialog_test.dart` 页面级测试，并扩展 `create_backup_page_test.dart`；两个测试文件共 20 项全部通过。
