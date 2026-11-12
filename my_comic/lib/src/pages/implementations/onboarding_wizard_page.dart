import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:my_comic/models.dart' show AppModel;
import 'package:my_comic/pages.dart';
import 'package:my_comic/src/media/import/real_path_directory_picker.dart';
import 'package:my_comic/src/onboarding/onboarding_steps.dart';
import 'package:my_comic/src/settings/settings_actions.dart'
    show buildLanguageSelector, buildBrightnessSelector;
import 'package:my_comic/src/settings/settings_context.dart';
import 'package:my_comic/src/storage/app_paths.dart';
import 'package:my_comic/src/storage/content_root_switch.dart';
import 'package:my_comic/src/utils/components/my_comic_staggered_entrance.dart';
import 'package:my_comic/src/utils/components/glass/my_comic_icon.dart';
import 'package:my_comic/src/utils/my_comic_color_roles.dart';
import 'package:my_comic/src/utils/my_comic_icons.dart';
import 'package:my_comic/utils.dart';

/// 三步漫画版新手引导：欢迎（语言/明暗）→ 选择 Content root → 完成说明。
///
/// 首次启动（`AppModel.needsOnboarding`）由 [HomePage] 首帧以
/// `fullscreenDialog` 推上来；之后可从「设置 → 系统与关于 → 重新打开新手引导」
/// 再打开。
///
/// 持久化副作用只有两个：
///  - 欢迎步复用外观设置的行选择器，语言/明暗改动立即生效并各自写偏好；
///  - 存储步选择目录后只写偏好（由 [ContentRootSwitch] 校验、建三个空目录并写
///    `content_root`），**不搬文件、不立即重启**。用户点「完成」时仅当 Content
///    root 相对进入向导时真的变了才重启；跳过 / 不换目录都不重启。
///
/// 版面沿用 Fushi v3.0.0 向导组件（浮动页头 + 分段进度条 + 共享 X 轴转场 +
/// hero 插画 + 底部导航行），不引入新的视觉语言。本页是 ADR 0008 UI fidelity
/// 的显式例外（见 ADR 0024）。
class OnboardingWizardPage extends BasePage {
  const OnboardingWizardPage({super.key});

  @override
  BasePageState<OnboardingWizardPage> createState() =>
      _OnboardingWizardPageState();
}

/// 测试缝：替换「校验并切换 Content root」。null = 生产 [ContentRootSwitch]。
///
/// 生产路径的真实校验 / 建目录 / 写偏好由 `test/storage/content_root_switch_test`
/// 覆盖；这里只让向导页的接线（展示新路径、完成时才重启）可被 widget 测试驱动。
@visibleForTesting
Future<ContentRootSwitchResult> Function(AppModel appModel, String picked)?
debugSwitchOnboardingContentRoot;

class _OnboardingWizardPageState extends BasePageState<OnboardingWizardPage>
    with SettingsContextHost<OnboardingWizardPage> {
  /// 步骤序列由纯函数生成（见 `src/onboarding/onboarding_steps.dart`）。
  final List<OnboardingStepId> _steps = onboardingStepSequence();

  int _stepIndex = 0;

  /// 最近一次换步的方向：决定共享轴转场往哪边滑。
  bool _navigatingForward = true;

  bool _completing = false;
  bool _choosing = false;

  /// 进入向导时的 Content root（重启判据的起点）与存储步当前选择。
  late String _initialContentRoot;
  late String _selectedContentRoot;

  @override
  void initState() {
    super.initState();
    final String root = appModelNoUpdate.appPathsOrNull?.contentRoot.path ?? '';
    _initialContentRoot = root;
    _selectedContentRoot = root;
  }

  void _goNext() {
    if (_stepIndex >= _steps.length - 1) {
      unawaited(_complete(restartIfChanged: true));
      return;
    }
    setState(() {
      _navigatingForward = true;
      _stepIndex += 1;
    });
  }

  void _goBack() {
    if (_stepIndex == 0) return;
    setState(() {
      _navigatingForward = false;
      _stepIndex -= 1;
    });
  }

  /// 选择 Content root：系统目录选择器 + 与设置页相同的校验 / 建目录 / 写偏好。
  /// 选择后只更新展示，不重启。
  Future<void> _chooseContentRoot() async {
    if (_choosing) return;
    _choosing = true;
    try {
      final String? picked = await pickRealDirectoryPath(
        context: context,
        appModel: appModelNoUpdate,
        dialogTitle: t.onboarding_storage_choose_button,
        initialDirectory: _selectedContentRoot.isEmpty
            ? null
            : _selectedContentRoot,
      );
      if (picked == null || picked.trim().isEmpty || !mounted) return;

      final ContentRootSwitchResult result = await _switchContentRoot(picked);
      if (!mounted) return;
      if (!result.succeeded) {
        MyComicToast.show(
          msg: _failureMessage(result.failure!),
          severity: ToastSeverity.error,
        );
        return;
      }
      setState(() => _selectedContentRoot = result.contentRoot!.path);
    } finally {
      _choosing = false;
    }
  }

  Future<ContentRootSwitchResult> _switchContentRoot(String picked) async {
    final Future<ContentRootSwitchResult> Function(AppModel, String)? hook =
        debugSwitchOnboardingContentRoot;
    if (hook != null) return hook(appModelNoUpdate, picked);

    final AppPaths? paths = appModelNoUpdate.appPathsOrNull;
    final Directory programStateRoot =
        paths?.programStateRoot ?? await AppPaths.programStateRootDirectory();
    final Directory defaultContentRoot =
        await AppPaths.defaultContentRootDirectory();
    return ContentRootSwitch(
      programStateRoot: programStateRoot,
      defaultContentRoot: defaultContentRoot,
      executablePath: Platform.resolvedExecutable,
    ).switchTo(picked);
  }

  /// 完成 / 跳过。完成偏好与 `first_time_setup` 先落盘，再决定是否重启。
  ///
  /// 只有 [restartIfChanged]（用户点「完成」）且 Content root 相对进入向导时
  /// 有变化才重启；跳过或目录没变都只关闭向导。重启失败沿用设置页的可见提示。
  Future<void> _complete({required bool restartIfChanged}) async {
    if (_completing) return;
    _completing = true;
    try {
      await appModelNoUpdate.setOnboardingCompleted(value: true);
      final bool changed =
          restartIfChanged &&
          onboardingRequiresRestart(
            initialContentRoot: _initialContentRoot,
            selectedContentRoot: _selectedContentRoot,
          );
      if (!mounted) return;

      if (changed) {
        final lifecycle = appModelNoUpdate.platformServices.lifecycle;
        if (!lifecycle.supportsRestart) {
          MyComicToast.show(msg: t.data_storage_switch_restart_required);
        } else {
          try {
            await lifecycle.restartApp();
            return;
          } catch (_) {
            if (mounted) {
              MyComicToast.show(
                msg: t.data_storage_switch_restart_failed,
                severity: ToastSeverity.error,
              );
            }
            return;
          }
        }
      }

      if (mounted) await Navigator.of(context).maybePop();
    } finally {
      _completing = false;
    }
  }

  static String _failureMessage(ContentRootSwitchFailure failure) =>
      switch (failure) {
        ContentRootSwitchFailure.notAbsolute =>
          t.data_storage_switch_failed_not_absolute,
        ContentRootSwitchFailure.installDirectory =>
          t.data_storage_switch_failed_install_dir,
        ContentRootSwitchFailure.insideProgramStateRoot =>
          t.data_storage_switch_failed_program_state,
        ContentRootSwitchFailure.notWritable =>
          t.data_storage_switch_failed_not_writable,
        ContentRootSwitchFailure.preferenceWriteFailed =>
          t.data_storage_switch_failed_preference,
      };

  @override
  Widget build(BuildContext context) {
    final OnboardingStepId step = _steps[_stepIndex];
    final bool isLast = _stepIndex == _steps.length - 1;

    // 页头只保留标题与进度条，不挂返回箭头：离开入口是底栏左侧的「跳过」，
    // 步骤间回退是底栏的「上一步」；左上角再放一个返回会让用户误以为回上一步。
    return MyComicPageScaffold(
      automaticallyImplyLeading: false,
      headerCompact: true,
      title: t.onboarding_title,
      headerBottom: OnboardingProgressBar(
        current: _stepIndex,
        total: _steps.length,
      ),
      body: OnboardingWizardBody(
        stepKey: step,
        forward: _navigatingForward,
        step: _buildStep(step),
        navigationBar: OnboardingNavigationBar(
          onSkip: isLast
              ? null
              : () => unawaited(_complete(restartIfChanged: false)),
          onBack: _stepIndex > 0 ? _goBack : null,
          onNext: _goNext,
          isLast: isLast,
        ),
      ),
    );
  }

  Widget _buildStep(OnboardingStepId step) => switch (step) {
    OnboardingStepId.welcome => _buildWelcomeStep(),
    OnboardingStepId.storage => _buildStorageStep(),
    OnboardingStepId.finish => _buildFinishStep(),
  };

  Widget _buildWelcomeStep() {
    final MyComicDesignTokens tokens = MyComicDesignTokens.of(context);
    final SettingsContext settingsContext = createSettingsContext(
      appModel: appModel,
      ref: ref,
    );
    return _OnboardingStepList(
      children: <Widget>[
        OnboardingStepHero(
          icon: MyComicIcons.home,
          title: t.onboarding_welcome_title,
          body: t.onboarding_welcome_intro,
        ),
        SizedBox(height: tokens.spacing.card),
        // 复用外观设置的行选择器（同一真相源），语言 / 明暗改动立即生效。
        MyComicCard(
          padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
          child: Column(
            children: <Widget>[
              buildLanguageSelector(settingsContext),
              buildBrightnessSelector(settingsContext),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStorageStep() {
    final MyComicDesignTokens tokens = MyComicDesignTokens.of(context);
    final String root = _selectedContentRoot;
    return _OnboardingStepList(
      children: <Widget>[
        OnboardingStepHero(
          icon: MyComicIcons.folder,
          title: t.onboarding_storage_title,
          body: t.onboarding_storage_intro,
        ),
        SizedBox(height: tokens.spacing.card),
        MyComicCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                t.onboarding_storage_content_root_label,
                style: textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              SizedBox(height: tokens.spacing.gap / 4),
              Text(root, style: textTheme.bodyLarge),
              SizedBox(height: tokens.spacing.card),
              MyComicFilledButton.icon(
                key: const ValueKey<String>('onboarding_choose_content_root'),
                onPressed: _choosing
                    ? null
                    : () => unawaited(_chooseContentRoot()),
                icon: const MyComicIcon(MyComicIcons.folderOpen),
                label: Text(t.onboarding_storage_choose_button),
              ),
              SizedBox(height: tokens.spacing.card),
              Text(
                t.onboarding_storage_folders_hint,
                style: textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              SizedBox(height: tokens.spacing.gap / 2),
              for (final (String label, String name) in <(String, String)>[
                (
                  t.data_storage_open_downloads_title,
                  AppPaths.downloadsDirName,
                ),
                (
                  t.data_storage_open_autobackup_title,
                  AppPaths.autobackupDirName,
                ),
                (
                  t.data_storage_open_local_comic_title,
                  AppPaths.localComicDirName,
                ),
              ])
                _OnboardingPathRow(
                  label: label,
                  path: root.isEmpty ? name : p.join(root, name),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFinishStep() {
    return _OnboardingStepList(
      children: <Widget>[
        OnboardingStepHero(
          icon: MyComicIcons.success,
          title: t.onboarding_finish_title,
          body: t.onboarding_finish_mihon_body,
        ),
      ],
    );
  }
}

/// 存储步里的一行「子目录名 + 最终绝对路径」。
class _OnboardingPathRow extends StatelessWidget {
  const _OnboardingPathRow({required this.label, required this.path});

  final String label;
  final String path;

  @override
  Widget build(BuildContext context) {
    final MyComicDesignTokens tokens = MyComicDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const MyComicIcon(MyComicIcons.folder, size: 20),
          SizedBox(width: tokens.spacing.gap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(label, style: Theme.of(context).textTheme.bodyMedium),
                Text(
                  path,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── 共享 widget（公开，便于脱离 AppModel 做 widget 测试）────────────────

/// 一步的正文列表：页边距统一，内容逐块错峰进场（spacer 不占错峰位）。
///
/// 必须在 [MyComicEntranceScope] 下使用（向导在每步的 keyed 子树根上挂了一个），
/// 否则窗口常开、滚动带出的块也会淡入。
class _OnboardingStepList extends StatelessWidget {
  const _OnboardingStepList({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final MyComicDesignTokens tokens = MyComicDesignTokens.of(context);
    int slot = 0;
    return ListView(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        // 正文滚到浮动页头（含进度条）底下：顶部让出「状态栏 + 页头」。
        tokens.spacing.card + MediaQuery.paddingOf(context).top,
        tokens.spacing.page,
        tokens.spacing.card,
      ),
      children: <Widget>[
        for (final Widget child in children)
          if (child is SizedBox && child.child == null)
            child
          else
            MyComicStaggeredEntrance(index: slot++, child: child),
      ],
    );
  }
}

/// 步骤之间的 M3E 共享 X 轴转场。
///
/// 前进：新步骤自右侧 30px 滑入、旧步骤向左让出；后退方向相反。位移走 spatial
/// 弹簧，透明度走 effects 弹簧；墨水屏 / 减弱动态效果下时长归零，切换瞬间完成。
class OnboardingStepSwitcher extends StatelessWidget {
  const OnboardingStepSwitcher({
    required this.stepKey,
    required this.forward,
    required this.child,
    super.key,
  });

  /// 当前步骤的身份；变化即触发一次转场。
  final Object stepKey;

  /// 本次换步是否前进（决定滑动方向）。
  final bool forward;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final MyComicSpringSpec spatial = context.myComicMotion.spatialDefault;
    final ValueKey<Object> currentKey = ValueKey<Object>(stepKey);
    return AnimatedSwitcher(
      duration: spatial.duration,
      layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
        fit: StackFit.expand,
        children: <Widget>[...previous, if (current != null) current],
      ),
      transitionBuilder: (Widget child, Animation<double> animation) {
        final bool incoming = child.key == currentKey;
        final double direction = forward ? 1 : -1;
        return _OnboardingSharedAxisX(
          animation: animation,
          incoming: incoming,
          offsetSign: incoming ? direction : -direction,
          spatialCurve: spatial.curve,
          child: child,
        );
      },
      child: KeyedSubtree(key: currentKey, child: child),
    );
  }
}

class _OnboardingSharedAxisX extends StatelessWidget {
  const _OnboardingSharedAxisX({
    required this.animation,
    required this.incoming,
    required this.offsetSign,
    required this.spatialCurve,
    required this.child,
  });

  final Animation<double> animation;
  final bool incoming;
  final double offsetSign;
  final Curve spatialCurve;
  final Widget child;

  /// M3 共享轴的位移距离。
  static const double _distance = 30;

  static const Interval _fadeIn = Interval(
    0.35,
    1,
    curve: MyComicSpringCurve.effects,
  );

  /// 退场时 animation 由 1 走向 0：取值落到 0.65 以下即完全透明。
  static const Interval _fadeOut = Interval(
    0.65,
    1,
    curve: MyComicSpringCurve.effects,
  );

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !incoming,
      child: AnimatedBuilder(
        animation: animation,
        child: child,
        builder: (BuildContext context, Widget? child) {
          final double t = animation.value;
          final double travel = 1 - spatialCurve.transform(t);
          return Opacity(
            opacity: (incoming ? _fadeIn : _fadeOut).transform(t),
            child: Transform.translate(
              offset: Offset(travel * _distance * offsetSign, 0),
              child: child,
            ),
          );
        },
      ),
    );
  }
}

/// 向导底部的导航行：左侧 text「跳过」，右侧 tonal「上一步」+ filled「下一步」。
///
/// 最后一步的主动作换成「完成」；「跳过」在最后一步隐藏。
class OnboardingNavigationBar extends StatelessWidget {
  const OnboardingNavigationBar({
    required this.onNext,
    required this.isLast,
    this.onSkip,
    this.onBack,
    super.key,
  });

  final VoidCallback onNext;
  final bool isLast;

  /// null = 不显示「跳过」（最后一步）。
  final VoidCallback? onSkip;

  /// null = 不显示「上一步」（第一步）。
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final MyComicDesignTokens tokens = MyComicDesignTokens.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.page,
          tokens.spacing.gap,
          tokens.spacing.page,
          tokens.spacing.card,
        ),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final MyComicButtonSize size = constraints.maxWidth >= 480
                ? MyComicButtonSize.m
                : MyComicButtonSize.s;
            return Row(
              children: <Widget>[
                if (onSkip != null)
                  MyComicTextButton(
                    key: const ValueKey<String>('onboarding_skip'),
                    size: size,
                    onPressed: onSkip,
                    child: Text(t.onboarding_action_skip),
                  ),
                const Spacer(),
                if (onBack != null) ...<Widget>[
                  MyComicFilledButton.tonal(
                    key: const ValueKey<String>('onboarding_previous'),
                    size: size,
                    onPressed: onBack,
                    child: Text(t.back),
                  ),
                  SizedBox(width: tokens.spacing.gap),
                ],
                MyComicFilledButton.icon(
                  key: const ValueKey<String>('onboarding_next'),
                  size: size,
                  onPressed: onNext,
                  iconAlignment: IconAlignment.end,
                  icon: MyComicIcon(
                    isLast ? MyComicIcons.check : MyComicIcons.forward,
                  ),
                  label: Text(
                    isLast
                        ? t.onboarding_action_finish
                        : t.onboarding_action_next,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 页头下方的分段进度指示：已走过的段用主色，当前段加粗，未到的段用轨道色；
/// 右侧是等宽数字「当前 / 总数」。
class OnboardingProgressBar extends StatelessWidget {
  const OnboardingProgressBar({
    required this.current,
    required this.total,
    super.key,
  });

  /// 当前步骤下标（0-based）。
  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    final MyComicDesignTokens tokens = MyComicDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool glass = isGlassDesign(context);
    final MyComicSpringSpec spring = context.myComicMotion.spatialDefault;
    final Color done = glass ? appleColorsOf(context).accent : colors.primary;
    final Color track = glass
        ? appleColorsOf(context).fill
        : isEinkTheme(context)
        ? colors.outlineVariant
        : colors.secondaryContainer;
    return Semantics(
      label: '${current + 1} / $total',
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.page,
          0,
          tokens.spacing.page,
          tokens.spacing.gap,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: SizedBox(
                height: 8,
                child: Row(
                  children: <Widget>[
                    for (int i = 0; i < total; i++)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: tokens.spacing.gap / 4,
                          ),
                          child: Center(
                            child: AnimatedContainer(
                              duration: spring.duration,
                              curve: spring.curve,
                              // Apple 不做长高：iOS 分段指示是一条等粗细线。
                              height: !glass && i == current ? 8 : 4,
                              decoration: BoxDecoration(
                                color: i <= current ? done : track,
                                borderRadius: tokens.radii.chipRadius,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SizedBox(width: tokens.spacing.gap),
            ExcludeSemantics(
              child: Text(
                '${current + 1} / $total',
                style: context.myComicType.labelLargeEmphasized.tabular.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 向导页的正文骨架（[MyComicPageScaffold.body]）：步骤内容居中限宽、走共享 X 轴
/// 切换，下面一条按钮行。
class OnboardingWizardBody extends StatelessWidget {
  const OnboardingWizardBody({
    required this.stepKey,
    required this.forward,
    required this.step,
    required this.navigationBar,
    super.key,
  });

  /// 当前步骤的身份；变化即触发一次转场。
  final Object stepKey;

  /// 本次换步是否前进（决定滑动方向）。
  final bool forward;
  final Widget step;
  final Widget navigationBar;

  /// 步骤内容区最大宽度：桌面宽窗口下正文行长过长会难读。
  static const double _contentMaxWidth = 720;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeBottom: true,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
                child: OnboardingStepSwitcher(
                  stepKey: stepKey,
                  forward: forward,
                  child: MyComicEntranceScope(child: step),
                ),
              ),
            ),
          ),
        ),
        navigationBar,
      ],
    );
  }
}

/// 每一步开头的 hero：插画式图标色块 + 大标题 + 一句说明，左对齐。
class OnboardingStepHero extends StatelessWidget {
  const OnboardingStepHero({
    required this.icon,
    required this.title,
    required this.body,
    super.key,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final MyComicDesignTokens tokens = MyComicDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final MyComicTypography type = context.myComicType;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (isGlassDesign(context))
          MyComicNeutralIconBadge(icon: icon, size: 64, iconSize: 32)
        else
          OnboardingHeroIllustration(icon: icon),
        SizedBox(height: tokens.spacing.card),
        Text(title, style: type.headlineMediumEmphasized),
        SizedBox(height: tokens.spacing.gap),
        Text(
          body,
          style: type.bodyLarge.copyWith(color: colors.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// [OnboardingStepHero] 的 M3E 插画式图标色块：主块复用对话框 hero，旁边点缀
/// 一枚 tertiary 四瓣 cookie 与一颗 secondary 圆点。每步是新的 keyed 子树，换步
/// 即重播。
class OnboardingHeroIllustration extends StatelessWidget {
  const OnboardingHeroIllustration({required this.icon, super.key});

  final IconData icon;

  static const double _blob = 104;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final MyComicSpringSpec spring = context.myComicMotion.spatialSlow;
    final BorderSide side = eink
        ? BorderSide(color: colors.outline)
        : BorderSide.none;
    Widget accent({
      required double size,
      required ShapeBorder border,
      required Color color,
    }) => TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: spring.duration,
      curve: Interval(0.3, 1, curve: spring.curve),
      builder: (BuildContext context, double v, Widget? child) =>
          Transform.scale(scale: v, child: child),
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: eink ? colors.surface : color,
            shape: border,
          ),
        ),
      ),
    );
    return ExcludeSemantics(
      child: SizedBox(
        width: _blob + 40,
        height: _blob + 12,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned(
              left: 0,
              top: 12,
              child: MyComicDialogHeroIcon(
                icon: icon,
                tone: MyComicHeroTone.primary,
                size: _blob,
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              child: accent(
                size: 40,
                border: MyComicCookieBorder(lobes: 4, side: side),
                color: colors.tertiaryContainer,
              ),
            ),
            Positioned(
              right: 18,
              bottom: 0,
              child: accent(
                size: 18,
                border: CircleBorder(side: side),
                color: colors.secondaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
