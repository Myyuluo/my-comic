/// 三步漫画版新手引导的纯数据模型。
///
/// 与 UI 解耦成顶层纯函数，便于单测「步骤固定、顺序稳定、门控与重启时机正确」，
/// 不必实例化整个向导页面（模式同 `home_page.dart` 的 [homeActiveTabs]）。
library;

import 'package:path/path.dart' as p;

/// 向导步骤身份（枚举身份而非整数下标，插入/裁剪步骤时不会打乱路由判断）。
enum OnboardingStepId {
  /// 欢迎 + 界面语言 / 明暗主题（复用外观设置的行选择器）。
  welcome,

  /// 选择 Content root，并展示 `downloads` / `autobackup` / `local` 最终路径。
  storage,

  /// 完成说明：MyComic 是 Mihon 兼容的桌面阅读器。
  finish,
}

/// 三步漫画版新手引导的固定序列：欢迎 → 内容文件夹 → 完成。
///
/// 恒新建列表：调用方（页面 State）可能按步骤增减做本地处理，不能污染下一次读取。
List<OnboardingStepId> onboardingStepSequence() => <OnboardingStepId>[
  OnboardingStepId.welcome,
  OnboardingStepId.storage,
  OnboardingStepId.finish,
];

/// 首帧是否显示新手引导。
///
/// 两个偏好共同门控：
///  - `first_time_setup`：本次安装是否还没跑完首启。默认 true；已有用户升级上来
///    时该键早已是 false，因此即使没有 `onboarding_completed` 也不会被打扰。
///  - `onboarding_completed`：默认 false（全新安装），完成/跳过引导后写 true。
bool shouldShowOnboarding({
  required bool firstTimeSetup,
  required bool onboardingCompleted,
}) => firstTimeSetup && !onboardingCompleted;

/// 点「完成」（或跳过）时是否必须重启：只比较起点与当前选择的 Content root。
///
/// 选择目录本身已经由 `ContentRootSwitch` 写入偏好，所以「先改到新目录再改回原
/// 目录」最终没有变化，不应重启；大小写与尾部分隔符按 Windows 路径语义视为同一
/// 位置（[p.equals] 在 Windows 上不区分大小写）。
bool onboardingRequiresRestart({
  required String initialContentRoot,
  required String selectedContentRoot,
}) {
  return !p.equals(
    p.canonicalize(initialContentRoot),
    p.canonicalize(selectedContentRoot),
  );
}
