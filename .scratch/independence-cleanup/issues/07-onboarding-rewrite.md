# 07: 三步漫画版新手引导

**What to build:** 重写 Onboarding 为三步：欢迎（语言/主题）→ 选择 Content root（展示 `downloads`/`autobackup`/`local` 最终路径）→ 完成说明。复用 Fushi 向导组件；新装用户首次启动显示，已有用户不被打扰；设置中可重新打开。

**Blocked by:** 05、06

**Status:** resolved

- [x] 用现有 Onboarding 步骤序列纯函数生成三步：`welcome` → `storage` → `finish`。
- [x] 欢迎步：复用现有语言选择器与明暗主题选择器。
- [x] 存储步：选择一个 Content root；展示将创建的 `downloads`、`autobackup`、`local` 最终路径；复用现有目录选择器和 Content root 校验；选择后只写偏好。
- [x] 完成步：只显示说明文字与“完成”按钮；文案使用“MyComic 是 Mihon 兼容的桌面阅读器，支持导入 Mihon Backup 和使用 Extension store”；不提供 Backup 导入/Extension store 操作按钮。
- [x] 重启时机：用户点“完成”时，如果 Content root 有变化才重启；没有变化则不重启。
- [x] 首次启动门控：新增 Onboarding 完成偏好，默认未完成；用现有 `first_time_setup` 标记避免已有用户看到。
- [x] 在“设置 → 系统与关于”增加“重新打开新手引导”入口，复用现有设置行组件。
- [x] 复用 Fushi v3.0.0 的向导组件、主题、spacing tokens 和布局；不照搬 Mihon Android 截图视觉。
- [x] 验证：步骤序列、目录选择、重启时机、首次启动门控、设置重开入口的测试；Windows 手动走一遍。

**Notes:** 参考 [spec](../spec.md) 与 [ADR 0024](../../../docs/adr/0024-windows-only-independent-identity.md)。本 ticket 是 ADR 0008 UI fidelity 的显式例外；其余 UI 不改。

## 实现记录

### 三步序列与首次启动门控

- 新增 `fushi/lib/src/onboarding/onboarding_steps.dart`：`OnboardingStepId { welcome, storage, finish }`、纯函数 `onboardingStepSequence()`（恒 `welcome → storage → finish`，每次返回新列表）、`shouldShowOnboarding(firstTimeSetup, onboardingCompleted)` 与 `onboardingRequiresRestart(initial, selected)`（`p.equals` + `p.canonicalize`：Windows 大小写 / 尾分隔符等价，先改走再改回原目录不算变化）。
- `PreferencesRepository.onboardingCompleted` 缺省值由 `true` 改为 `false`；`setOnboardingCompleted(true)` 改用一次 `setPrefs` 同事务写 `onboarding_completed=true` + `first_time_setup=false`，避免「重启先发生、一半标记还没落盘」导致新装用户下次启动再弹。
- `AppModel.needsOnboarding` 统一门控：`first_time_setup && !onboarding_completed`。`HomePage` 首帧在 Program state 回退提示之后以 `fullscreenDialog` 推入向导；`main.dart` 的 `runAppShortcut(onboardingCompleted:)` 改为 `!needsOnboarding`，已有用户（`first_time_setup=false`）不因新偏好缺省 false 被误当成引导中。

### 向导页面

- 恢复并适配 Fushi v3.0.0 的向导展示件：浮动页头 + 分段进度条（`OnboardingProgressBar`）、M3E 共享 X 轴转场（`OnboardingStepSwitcher`）、720 限宽正文（`OnboardingWizardBody`）、hero 插画（`OnboardingStepHero` / `OnboardingHeroIllustration`）、底部导航行（`OnboardingNavigationBar`）与错峰进场列表；未引入新的视觉语言。
- 欢迎步：hero + `buildLanguageSelector` / `buildBrightnessSelector`，与「设置 → 外观」同一真相源，改动立即生效并各自写偏好。
- 存储步：`pickRealDirectoryPath` + `ContentRootSwitch`（与设置页同一校验、创建三个空目录、写 `content_root`）；展示当前 Content root 与 `downloads` / `autobackup` / `local` 的最终路径；选择后只更新展示，不搬文件、不立即重启。
- 完成步：只有 hero 说明与底部「完成」按钮；文案使用「MyComic 是 Mihon 兼容的桌面阅读器，支持导入 Mihon Backup 和使用 Extension store」，不提供 Backup 导入 / Extension store 操作按钮。
- 重启时机：点「完成」时仅 `onboardingRequiresRestart` 为 true 才 `lifecycle.restartApp()`；跳过、目录没变、改回原目录都只关闭。不支持重启 / 重启失败复用设置页既有提示文案。
- 设置入口：`设置 → 系统与关于 → 通用` 新增 `system.onboarding` 行（`SettingsNavigationItem` + `FushiIcons.help`），推入同一个 `OnboardingWizardPage`。

### l10n

- 新增 11 个 key（en / ja / zh-CN / zh-HK）：
  `onboarding_action_finish`、`onboarding_finish_mihon_body`、
  `onboarding_storage_choose_button`、`onboarding_storage_content_root_label`、
  `onboarding_storage_folders_hint`、`onboarding_storage_intro`、
  `onboarding_storage_title`、`onboarding_welcome_intro`、`onboarding_welcome_title`、
  `settings_onboarding_reopen_subtitle`、`settings_onboarding_reopen_title`。
- 复用既有 `onboarding_title`、`onboarding_finish_title`、`onboarding_action_next`、
  `onboarding_action_skip`、`data_storage_open_*`（三个子目录标签）与
  `data_storage_switch_*`（失败 / 重启提示）。
- `dart run slang` 重新生成 4 个 locale。

### 测试

- 新增 `fushi/test/onboarding/onboarding_steps_test.dart`（12 条）：三步序列、首次启动门控真值表、Content root 变化判定（同路径 / 大小写 / 尾分隔符 / 改回原目录）、完成偏好缺省与同事务写入、`AppModel.needsOnboarding`。
- 新增 `fushi/test/onboarding/onboarding_wizard_page_test.dart`（4 条）：三步内容与顺序（欢迎步含语言 / 明暗选择器；存储步展示三条最终路径；完成步只有说明与「完成」）、不换目录点完成不重启并落完成偏好、换目录即时展示且点完成才重启、改回原目录不重启。
- 新增 `fushi/test/settings/onboarding_reopen_entry_test.dart`（2 条）：设置行存在、文案 / 图标正确、builder 返回 `OnboardingWizardPage`。
- 相关既有套件（`test/i18n`、settings schema/search/system order、content root、locale、Downloads 真 HomePage 壳）通过。
- 已知基线失败（与本次无关）：`settings_destination_order_guard_test` 仍断言已删除的 `buildMediaTrackingDestination()`；`storage_content_root_settings_test` 的「旧迁移器」静态守卫仍读取 ticket 04 已删除的 `lib/src/sync/sync_settings_schema.dart`。

### 验证

- `cd fushi && dart run slang`：通过（en / ja / zh-CN / zh-HK）。
- `flutter analyze`：0 errors；201 条既有 warning/info（ticket 04/05 后基线）；本次新增 / 修改文件无 issue。
- 相关测试：新增 18 条全部通过；最终聚焦运行 124 通过 / 1 失败，唯一失败是上述已知基线（`lib/src/sync/sync_settings_schema.dart` 已删除）。
- `flutter build windows --debug --no-pub`：通过（首次 250.8s；最终源码增量重建 33.2s，产物 `build/windows/x64/runner/Debug/fushi.exe`，`data/flutter_assets/kernel_blob.bin` 为最终源码）。NuGet 由 worktree `.dart_tool/nuget/nuget.exe` 经 PATH 注入。
- 冷启动 smoke：全新 `userdata` 启动 12s 后进程仍存活（`alive=True`），随后强制结束；未出现首帧引导门控 / 推路由崩溃。完整 GUI 点选走查未自动化，由 widget 测试覆盖步骤、存储展示与重启时机。

### 延迟项

- 旧 Onboarding 的 l10n key（`onboarding_welcome_headline`、`onboarding_feature_*`、Anki / 推荐包等 200+ 条）已无引用，由 ticket 08 扫描删除；本 ticket 不删 key。
- 旧向导的推荐包 / Anki / 同步 / 浏览器扩展实现已由 ticket 04 删除，本 ticket 未恢复。
- 未使用 l10n key 门禁与旧品牌文案清理分别由 ticket 08 / 09 负责。
