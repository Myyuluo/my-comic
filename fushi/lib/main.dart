import 'dart:async';
import 'dart:io';
import 'package:fushi/src/media/manga/library/manga_add_to_shelf_prompt.dart';
import 'package:fushi/src/media/media_item_factory.dart';
import 'dart:ui' show PlatformDispatcher;
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/platform/desktop/windows_owned_file_picker.dart';
import 'package:fushi/src/utils/adaptive/legacy_design_compat.dart';
import 'package:fushi/src/focus/main_window_focus_gate.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:stack_trace/stack_trace.dart';
import 'package:fushi/src/utils/misc/screen_wakelock.dart';
import 'package:window_manager/window_manager.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show buildFushiFallbackTheme;
import 'package:fushi/pages.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/misc/app_icon_preferences.dart';
import 'package:fushi/src/utils/misc/flutter_error_log.dart';
import 'package:fushi/src/utils/misc/present_watchdog.dart';
import 'package:fushi/src/utils/misc/shortcut_icon_sync.dart';
import 'package:fushi/src/utils/misc/smooth_wheel_scroll.dart';
import 'package:fushi/src/utils/misc/hang_watchdog_log.dart';
import 'package:fushi/src/utils/rasterized_frame_size_reporter.dart';
import 'package:fushi/src/utils/settled_theme.dart';
import 'package:fushi/src/utils/window_caption_channel.dart';
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/shortcuts/global_navigation.dart';
import 'package:fushi/src/startup/desktop_window_placement.dart';

import 'package:fushi/src/settings/settings_schema.dart'
    show resetSettingsSchemaCache;
import 'package:fushi/src/startup/loading_watchdog_view.dart';
import 'package:fushi/src/startup/webview_prewarm.dart';
import 'package:fushi/src/startup/exit_flush_registry.dart';
import 'package:fushi/src/startup/program_state_shared_preferences.dart';
import 'package:fushi/src/startup/test_root_shared_preferences.dart';
import 'package:fushi/src/storage/webview2_state_root.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/platform/source_url_channel.dart';
import 'package:fushi/src/platform/desktop/desktop_ctl_host.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_library_entries.dart';
import 'package:fushi_cli/fushi_cli.dart' show CtlOpenResult, CtlServer;
import 'package:fushi/src/platform/app_shortcuts.dart';
import 'package:fushi/src/platform/app_shortcut_router.dart';
import 'package:fushi/src/platform/windows_ime_guard.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/engine_deep_link_route_guard.dart';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart'
    show
        BookFormat,
        EpubBookRow,
        FushiDatabaseFailureKind,
        kLegacySchemaBridgeAppVersion,
        kLegacySchemaBridgeReleaseUrl,
        ProfileMediaKind,
        VideoBookRow,
        VideoBooksCompanion;
import 'package:fushi/src/media/media_item.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/src/engine_bindings.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cloudflare_challenge.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:fushi/src/utils/system_transparency.dart';

Color? _savedSplashColor;

bool _deferStartupFrame = false;

/// Single source of truth for the status/navigation bar overlay style.
///
/// Maps an app [brightness] to the matching system bar icon brightness while
/// keeping both bars transparent + uncontrasted for edge-to-edge layout. Used
/// both at startup (keyed off the platform brightness, to avoid a white flash
/// before init) and at runtime via an [AnnotatedRegion] keyed off the live
/// theme brightness, so the system navigation bar follows in-app theme
/// switches instead of being frozen at the launch-time platform brightness.
SystemUiOverlayStyle fushiSystemOverlayStyle(Brightness brightness) {
  // A dark app surface needs light (bright) bar icons; a light surface needs
  // dark icons. We set the icon brightnesses *explicitly* rather than reuse
  // SystemUiOverlayStyle.light/.dark, because both of those presets hardcode
  // systemNavigationBarIconBrightness: Brightness.light (they assume an opaque
  // black nav bar). With our transparent edge-to-edge nav bar that would leave
  // the gesture pill / buttons light on a light theme — invisible, and frozen
  // across theme switches.
  final iconBrightness = brightness == Brightness.dark
      ? Brightness.light
      : Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: iconBrightness,
    // iOS: statusBarBrightness is the *background* brightness behind the bar.
    statusBarBrightness: brightness,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: iconBrightness,
    systemNavigationBarContrastEnforced: false,
  );
}

/// Application execution starts here.
///
/// [args] are the Dart entrypoint arguments. On Windows the runner forwards the
/// process argv (minus the binary name) via `set_dart_entrypoint_arguments`, so
/// opening a video with Fushi (file association / drag-onto-exe / CLI) lands the
/// video path here. We stash the first supported video path for the widget tree
/// to act on once the app has finished initialising.
void main([List<String> args = const <String>[]]) {
  /// Run and handle an error zone to customise the action performed upon
  /// an error or exception. This allows for error logging for debug purposes
  /// as well as communicating errors to Crashlytics if enabled.
  runZonedGuarded<Future<void>>(
    () async {
      /// Necessary to initialise Flutter when running native code before
      /// starting the application.
      final binding = WidgetsFlutterBinding.ensureInitialized();
      final bool hiddenTestMode =
          Platform.environment['FUSHI_TEST_HIDDEN']?.isNotEmpty == true ||
          Platform.environment.containsKey('HIBIKI_TEST_HIDDEN');
      _deferStartupFrame = !hiddenTestMode;
      if (_deferStartupFrame) binding.deferFirstFrame();
      // 测试根（FUSHI_TEST_ROOT）下 SharedPreferences 也要隔离，且必须抢在下面第一次
      // 读 prefs 之前：否则集成测试写的设置会落进用户真实的 prefs 文件。
      isolateSharedPreferencesUnderTestRoot();
      // Ticket 01：prefs 与数据库、Mihon runtime 一起住在 Program state root 的
      // `state/`（`<exeDir>/userdata/state/shared_preferences.json`），不再落在
      // `%APPDATA%`。测试根生效时上一步已装好隔离 store，这里是幂等 no-op。
      isolateSharedPreferencesUnderProgramStateRoot();
      // Ticket 02：WebView2 的 user data folder（站点登录态 / cookie）属于 Portable
      // state，固定到 `<programState>/state/webview2`。必须早于任何 WebView 创建：
      // WebView2 只在 CreateCoreWebView2EnvironmentWithOptions 时接受 folder。
      WebView2StateRoot.install();
      // Ticket 01 / fresh start：不搬、也不读旧 Fushi / Hibiki 的 app-support 数据
      // （`%APPDATA%` / NSUserDefaults 旧域）。旧目录由用户自行删除。
      // ASR 算法层住在独立包（fushi_asr_core），它的数据根 / 出站 HTTP / 日志三个装配点
      // 由宿主装上。放在这里而不是 `AppModel.initialise()`：装的全是同步工厂，没有
      // 时序前置条件，而 `initialise()` 有两个 entry point 绕开它（弹窗词典与悬浮
      // 词典），写在 main 里哪个入口都不会漏。
      installEngineHostBindings();
      // BUG-3286：Windows 系统文件对话框以主窗为 owner，视频全屏（TOPMOST）时不被压住。
      installWindowsOwnedFilePicker();
      // 系统「降低透明度」信号（Windows / macOS / iOS），玻璃设计系统据此回退实心。
      unawaited(SystemTransparency.initialize());
      AppIconSelection startupAppIcon = currentAppIconSelection.value;
      try {
        // BUG-1920：在 runApp 前把持久化选择灌入 Flutter 侧唯一真值，避免侧栏
        // 第一帧先画固定旧图标，直到用户重新打开设置页才刷新。
        startupAppIcon = await loadAppIconSelection();
      } catch (e) {
        debugPrint('[Fushi] app icon preference restore failed: $e');
      }
      // BUG-2462：Windows 子窗 resize 闸门的确认信号。必须在 runApp 之前挂——
      // 首帧起 runner 就在等这条上报来确认它交付的第一个尺寸。
      installRasterizedFrameSizeReporter();
      if (Platform.isWindows) {
        await windowManager.ensureInitialized();
        await WindowCaptionChannel.beginStartupWindowPreparation();
        try {
          if (Platform.isWindows) {
            // window_manager's Windows plugin implements setTitleBarStyle as a
            // string assignment + SetWindowPos and always reports success, so there
            // is no failure mode to fall back from here (the macOS plugin likewise
            // just flips NSWindow properties). The app frame is therefore
            // unconditional on both hosts once the plugin is initialised.
            //
            // macOS 也用自绘顶栏：`hidden` 在 macOS 上是 `titleVisibility=.hidden` +
            // `titlebarAppearsTransparent` + `fullSizeContentView`（AppKit 仍拥有
            // 四边 resize 边框）。窗口按钮按平台：
            // 2026-10-04 用户改主意：macOS 无论设计系统一律用系统原生红绿灯（自绘
            // 顶栏左侧给它们留位，内容全屏时由 FushiDesktopTitleBar 隐藏），
            // Windows / Linux 仍是 MD3 按钮。
            await windowManager.setTitleBarStyle(
              TitleBarStyle.hidden,
              windowButtonVisibility: false,
            );
            FushiDesktopTitleBar.markEnabled();
          }
          // BUG-1619：主窗前台真值的唯一来源，必须在 window_manager 初始化之后、
          // 任何页面挂载之前起来——焦点闸门与焦点控制器都读它。
          MainWindowForegroundWatcher.instance.start();
          await DesktopWindowPlacement.applyInitialPlacement();
        } finally {
          await WindowCaptionChannel.endStartupWindowPreparation();
        }
        // Intercept the native window-close signal so we can tear down Bonsoir's
        // mDNS event sources (LAN broadcast + discovery) BEFORE the Flutter engine
        // exits. Without this, a queued mDNS event delivered to a torn-down
        // messenger crashes the process on exit (TODO-036, Windows). The actual
        // event-source cut + fast exit runs in
        // [_FushiReaderAppState.onWindowClose] (TODO-086).
        await windowManager.setPreventClose(true);
        // Windows runner keeps the main window hidden until the first usable
        // home or error frame has reached the raster thread.
        await hotKeyManager.unregisterAll(); // 热重载清理残留全局热键
        // 运行时按持久化偏好重应用窗口/任务栏图标（Windows exe 静态图标改不了，
        // 启动后由 setWindowIcon 覆盖成用户所选预设/自定义图）。失败静默降级。
        if (Platform.isWindows) {
          try {
            final String? iconPath = startupAppIcon.usesCustomFile
                ? startupAppIcon.customPath
                : await exportPresetIconToFile(startupAppIcon.presetKey);
            if (iconPath != null && File(iconPath).existsSync()) {
              final bool applied = await WindowCaptionChannel.setWindowIcon(
                iconPath,
              );
              if (applied) {
                // TODO-901：安装器更新可能把桌面 / 开始菜单 / 任务栏固定项的
                // IconLocation 重置回 exe；同一档图标又不能靠重新点选触发设置页同步。
                // 冷启动成功恢复窗口图标后，用同一源文件字节重写 .lnk 以自愈。
                // 不 await：这里还在 runApp 之前，.lnk 自愈是尽力而为、与首帧无关，
                // 没有理由让每次启动都等它（编码 + 原生改写 + shell 通知）。
                unawaited(() async {
                  try {
                    final Uint8List iconBytes = await File(
                      iconPath,
                    ).readAsBytes();
                    await syncWindowsShortcutIcons(iconBytes);
                  } catch (e) {
                    debugPrint('[Fushi] shortcut icon sync failed: $e');
                  }
                }());
              }
            }
          } catch (e) {
            debugPrint('[Fushi] window icon restore failed: $e');
          }
        }
      }
      // 液态玻璃材质的着色器预热：只把 FragmentProgram 读进内存，免得第一次打开
      // 弹层时闪一帧占位。纯 IO、与启动无依赖，后台跑不挡首帧；没开 liquid 档的
      // 用户也只是多读几个着色器文件。
      unawaited(LiquidGlassWidgets.initialize(enablePerformanceMonitor: false));

      // BUG-1015 的查词播放器冷启动静音预热**不在启动路径**（BUG-1690）：预热要在真实
      // 音频输出设备上开渲染流，启动即预热会打断其他 app 正在播的音乐（iOS 激活音频会话
      // 直接暂停对方；蓝牙多点/独占输出被抢走）。预热已改为惰性——首次真实查词播放前，
      // 由桌面查词播放器在自身的激活串行队列里就地执行（见 desktop_audio_playback.dart），
      // BUG-1015 的保护不变。启动路径不得新增任何打开音频输出流的调用。
      // （BUG-1093 弹窗 WebView <audio> 首次无声是 WebView2 autoplay 策略，与此无关。）

      /// Ensure no pop-in for the selected app icon. Precaching is a best-effort
      /// optimisation: if the decode fails (e.g. the CI software-GPU emulator
      /// can't decompress the PNG → "Could not decompress image", or low memory),
      /// it must NOT surface as an unhandled FlutterError — that would both spam
      /// error reporting on real devices and fail the appSmoke integration test.
      /// Swallow it via precacheImage's onError; the icon just falls back to a
      /// one-frame decode-on-demand later.
      binding.addPostFrameCallback((_) async {
        final context = binding.rootElement;
        if (context != null) {
          precacheImage(
            appIconImageProvider(startupAppIcon),
            context,
            onError: (Object error, StackTrace? stack) {
              debugPrint('[startup] app icon precache skipped: $error');
            },
          );
        }
      });

      /// Ensure wake prevention is disabled if not reverted from entering a
      /// media source. setScreenWakelock never throws (failures such as a missing
      /// org.freedesktop.ScreenSaver D-Bus service on Linux are only logged).
      unawaited(setScreenWakelock(enable: false, source: 'startup'));
      // Match system bar overlays to the platform brightness immediately so the
      // status bar and navigation bar don't flash white on dark-mode devices.
      final platformBrightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      SystemChrome.setSystemUIOverlayStyle(
        fushiSystemOverlayStyle(platformBrightness),
      );

      /// Some packages propagate their [StackTrace] in an unusual format as
      /// opposed to the format generated by Dart. This function allows the
      /// Flutter framework to handle such formats so they can be displayed
      /// appropriately.
      FlutterError.demangleStackTrace = (stack) {
        if (stack is Trace) {
          return stack.vmTrace;
        }
        if (stack is Chain) {
          return stack.toTrace().vmTrace;
        }
        return stack;
      };

      /// Construct platform-specific service implementations once, before the
      /// provider container is created.  This value object is injected into both
      /// [platformServicesProvider] (for widget-layer access) and [AppModel]
      /// (via [appProvider]).
      final platformServices = PlatformServices.forCurrentPlatform();

      /// Create the provider container before running the app so the same
      /// [AppModel] instance is shared between the widget tree and the
      /// initialisation call below.
      final container = ProviderContainer(
        overrides: [
          platformServicesProvider.overrideWithValue(platformServices),
        ],
      );

      /// BUG-1450：Windows 上没有文本框持焦时解除窗口的 IME 关联，否则中文输入法
      /// 会吞掉每一个按键（引擎把它们报成 physical=0/logical=0），整张快捷键表失效。
      /// 必须在 runApp 之前挂上：install 会立刻同步一次，冷启动第一帧起就生效。
      WindowsImeGuard.install();

      /// Start the application immediately so the user sees the loading page
      /// rather than a blank white screen while initialisation is in progress.
      runApp(
        UncontrolledProviderScope(
          container: container,
          child: const FushiReaderApp(),
        ),
      );

      /// Initialise error log service.
      await ErrorLogService.instance.init();
      // 下面四步都只依赖错误日志已就绪、彼此独立（各自读写自己的文件 / 通道），
      // 并发跑；串行 await 四段小 IO 是启动到 LoadingPage 之前的纯等待。
      await Future.wait<void>(<Future<void>>[
        DebugLogService.instance.init(),
        // TODO-1232 A3：读一次 native 持久化的渲染后端选择（关 Impeller 实验开关），
        // 供设置项同步渲染。非 Android 静默降级为不支持。
        RenderBackendService.instance.init(),
        // BUG-772：把上次运行 present 楔死取证（首帧从未 rasterize）折进错误日志（仅
        // Windows），纳入上传链路，为 raster/present 管线死锁提供可读崩前证据。
        PresentStallLog.foldIntoErrorLog(),
        // BUG-2588：把上次运行主线程停泵看门狗抓 hang dump 的记录折进错误日志（仅
        // Windows），让「卡死后强杀」在日志里与 native 崩溃分开、并指向可分享的 hang-*.dmp。
        HangWatchdogLog.foldIntoErrorLog(),
      ]);

      /// Run the heavy initialisation after the first frame has been scheduled.
      /// [AppModel.isInitialised] will flip to true and notify listeners when
      /// done, causing [FushiReaderApp] to navigate from [LoadingPage] to
      /// [HomePage].
      final appModel = container.read(appProvider);
      await appModel.initialise();

      // ── 预热 WebView 引擎 ──────────────────────────────────────────────
      // 用户还在看主页/书架时就把冷启动成本吃掉：~500-1500ms。
      // 移动端可直接预热；桌面端（WebView2）必须等首帧渲染、Flutter view
      // 已挂载后再构造 HeadlessInAppWebView，否则会崩 WebView2。

      if (shouldPrewarmWebView(
        isMobile: false,
        isDesktop: true,
        lowMemory: appModel.lowMemoryMode,
      )) {
        unawaited(
          Future(() async {
            // 预热持有的是进程级资源（一个 headless WebView = 一个 chromium
            // renderer 子进程），销毁必须有确定终点，不能只挂在 onLoadStop 这条
            // 成功路径上：回调不来就是永久泄漏一个 renderer，而 renderer 被 OOM
            // kill 且 onRenderProcessGone 无人接管时，Android 默认会连整个 app
            // 进程一起杀（CI Android appSmoke 连续 4 次死于此）。终点交给
            // WebViewPrewarmSession 收口：载入完成 / 载入失败 / renderer 死亡 /
            // 超时兜底，先到者胜、只 dispose 一次。
            late final HeadlessInAppWebView warmup;
            final WebViewPrewarmSession session = WebViewPrewarmSession(
              disposeWebView: () => warmup.dispose(),
              onFinished: (String reason) =>
                  debugPrint('[Fushi] WebView engine pre-warm ended: $reason'),
            );
            try {
              // 桌面端等首帧，保证 Flutter view 已 attach（WebView2 前提）。
              await WidgetsBinding.instance.endOfFrame;
              warmup = HeadlessInAppWebView(
                initialUrlRequest: URLRequest(url: WebUri('about:blank')),
                onLoadStop: (controller, url) async {
                  // 100ms 让 onLoadStop 的回调栈先出栈再销毁：这是原实现就有的
                  // 保守做法（桌面 WebView2 上在回调里同步 dispose 曾不稳），
                  // 不是等待载入的重试窗口——真正的终点保证在 session 那边。
                  await Future.delayed(const Duration(milliseconds: 100));
                  await session.finish('loaded');
                },
                onReceivedError: (controller, request, error) =>
                    session.finish('load error: ${error.type}'),
                // 接管 renderer 死亡：Android 侧只要注册了这个回调，
                // InAppWebViewClient 就返回 true，chromium 不再连坐杀 app 进程。
                onWebContentProcessDidTerminate: (controller) =>
                    session.finish('webkit content process terminated'),
                onRenderProcessGone: (controller, detail) => session.finish(
                  'renderer gone (didCrash=${detail.didCrash})',
                ),
              );
              await warmup.run();
              session.armTimeout();
            } catch (e) {
              debugPrint('[Fushi] WebView warmup failed (non-fatal): $e');
              await session.finish('run failed: $e');
            }
          }),
        );
      }

      // galgame helper 与 Magpie 都只从 Windows 主包随附归档安装（BUG-1196 / BUG-1292）。
      // 版本与 app 强绑定：要新组件就更新 Fushi。不要恢复后台静默下载或旧包联网兜底。

      /// Capture Flutter framework errors with full details.
      FlutterError.onError = (details) {
        // Suppress known Flutter framework bug: RawTooltipState creates
        // multiple tickers from SingleTickerProviderStateMixin.
        final msg = details.exceptionAsString();
        if (msg.contains('SingleTickerProviderStateMixin') &&
            msg.contains('RawTooltipState')) {
          return;
        }
        FlutterError.presentError(details);
        // BUG-2496：框架自己标 `silent: true` 的错误（图片解码失败等
        // `MultiFrameImageStreamCompleter` 上报的非致命错误）不是崩溃前兆，
        // 只留诊断痕迹（不计入错误计数、不同步 flush），别把一张坏封面记成致命错误。
        if (details.silent) {
          ErrorLogService.instance.logDiagnostic(
            flutterErrorLogSource(details),
            '$msg\n${details.stack}',
          );
          return;
        }
        // TODO-607 P0-1：FlutterError 是致命级，用同步 flush 落盘——若这条错误紧接着把
        // 进程带崩（如 build/layout 期的 native 回调异常），异步 append 来不及写盘。
        ErrorLogService.instance.logFatal(
          flutterErrorLogSource(details),
          msg,
          details.stack,
        );
      };

      /// TODO-607 P0-1：平台/引擎层未捕获的异步错误（platform message handler、
      /// 原生回调、microtask 等）不经 [FlutterError.onError] 也不一定经
      /// [runZonedGuarded] 的 onError——它们走 [PlatformDispatcher.onError]。此前没装
      /// 这个钩子，这类错误对错误日志完全不可见（用户报「错误日志一片空白」的一类
      /// 来源）。装上后用同步 flush 落盘（致命级），返回 true 标记「已处理」，避免
      /// 引擎把它再当未处理崩溃上报。
      PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
        ErrorLogService.instance.logFatal('PlatformDispatcher', error, stack);
        return true;
      };
    },
    (exception, stack) {
      /// Log the error. UncaughtZone 是致命级（zone 顶层未捕获），同步 flush 落盘
      /// （TODO-607 P0-1）——这条之后进程往往就终止了，异步 append 来不及写盘。
      ErrorLogService.instance.logFatal('UncaughtZone', exception, stack);
    },
  );
}

/// Encapsulates theming, spacing and other configurable options pertaining to
/// the entire app, with some parameters dependent on the [AppModel].
class FushiReaderApp extends ConsumerStatefulWidget {
  /// Initialises an instance of the app.
  const FushiReaderApp({super.key});

  @override
  ConsumerState<FushiReaderApp> createState() => _FushiReaderAppState();
}

class _FushiReaderAppState extends ConsumerState<FushiReaderApp>
    with WidgetsBindingObserver, WindowListener {
  final navigatorKey = GlobalKey<NavigatorState>();


  /// 长按 app 图标点下的快捷方式（`fushi://shortcut/<id>`）。冷启动时 URL 比
  /// `initialise()` 先到，而 HomePage.initState 会把 [homeShellTabNotifier]
  /// 重置成启动 tab，所以先排队，等 home 挂载后的首帧再落地。
  late final AppShortcutQueue _appShortcuts = AppShortcutQueue(
    isActive: () => mounted,
    run: _runAppShortcut,
  );

  /// TODO-904 P0 回归：Windows 单实例守卫下，第二实例（文件关联 / 拖到 exe / CLI
  /// `fushi.exe "%1"`）不会自己起窗口，而是把视频路径经 WM_COPYDATA 转交首实例
  /// （见 `windows/runner/external_video_handoff.*` + `flutter_window.cpp`）。首实例
  /// 经此 MethodChannel 收到 `openExternalVideo`，复用现有 [_openExternalVideo]
  /// 打开链路。Linux 同一条通道：GTK runner 以 GApplication 单实例注册到会话
  /// D-Bus，第二次启动的 argv 经 `command-line` 信号落到首实例再推过来（见
  /// `linux/runner/my_application.cc`）。macOS 走 `source_urls` 事件流与系统
  /// open-file 事件，不注册本通道。
  /// TODO-1092: Windows 系统强调色/主题色实时变更通知 channel。runner 侧
  /// （`windows/runner/flutter_window.cpp` 的 MessageHandler）收到
  /// WM_DWMCOLORIZATIONCOLORCHANGED / WM_SETTINGCHANGE("ImmersiveColorSet") /
  /// WM_THEMECHANGED 后经此 channel 推 `onSystemColorChanged`，Dart 侧据此调
  /// [AppModel.refreshSystemPalette] 让动态取色实时刷新（不再等生命周期 resumed）。
  static const MethodChannel _systemThemeChannel = MethodChannel(
    'app.fushi/system_theme',
  );

  /// 去抖：一次系统色变更常连发多条 Win32 广播（DWM + ImmersiveColorSet +
  /// THEMECHANGED），合并到一次 [AppModel.refreshSystemPalette]，避免同一变更重复
  /// 取色 + notifyListeners 抖动。
  Timer? _systemColorRefreshDebounce;

  /// 守卫：退出清理（停 Bonsoir 事件源）只跑一次，避免 [onWindowClose] 与
  /// [didChangeAppLifecycleState] 的 `detached` 兜底重复触发。
  bool _shutdownStarted = false;

  /// 桌面本机控制通道（`fushi_cli` 的服务端，见 [_startCtlServer]）。
  CtlServer? _ctlServer;

  /// 退出总预算。窗口在 flush 开始前就已隐藏，这个上界只决定「进程最多在后台多待
  /// 多久」，不影响用户看到的关闭速度。取 6s：足够覆盖最坏情况下的 Mihon sidecar
  /// 关停（~1.8s）与关书同步 drain（5s 上界，实际多为 0），外加 checkpoint 余量。
  static const Duration _exitWatchdogTimeout = Duration(seconds: 6);

  /// 关库上界。WAL 崩溃安全，超时放行只损失一次 checkpoint，不损失已提交的数据。
  static const Duration _closeDatabaseOnExitTimeout = Duration(seconds: 3);

  /// 守卫：Windows 安装器 handoff reconcile 的 post-frame 调度只挂一个。
  bool _windowsUpdateHandoffScheduled = false;

  /// TODO-1260：启动加载「看门狗」。裸 loading 分支（[!appModel.isInitialised]）此前只有
  /// 一个**无超时**的 [CircularProgressIndicator]——若 `initialise()` 因某早期 IO（掉线
  /// 数据根盘的 stat / 目录创建）永不返回，就无限转圈、无任何逃生口（TODO-1260「偶发
  /// 无限加载」根因之一）。看门狗在进入裸加载态时启动，超过 [_loadingWatchdogTimeout]
  /// 仍未初始化完成就翻 [_loadingTimedOut]，加载分支改渲染「耗时超预期 + 说明 + 重试」
  /// 逃生 UI，消除「无 escape」的结构缺陷（Layer 1/2 的数据根超时降级是主修，这层是
  /// 兜底：任何未预见的启动挂起都有可点的出口，而非死转圈）。
  static const Duration _loadingWatchdogTimeout = Duration(seconds: 20);
  Timer? _loadingWatchdog;
  bool _loadingTimedOut = false;
  bool _startupFrameReleaseScheduled = false;
  bool _initialThemePresented = false;
  bool _initialThemeRestoreScheduled = false;

  /// BUG-772：present-watchdog 超时（比 20s 裸加载看门狗更长，确认是硬故障而非 IO 慢）。
  static const Duration _presentWatchdogTimeout = Duration(seconds: 30);

  /// BUG-772：present 层死锁兜底看门狗（仅 Windows arm）。UI-isolate 看门狗的逃生 UI 在
  /// raster/present 楔死时也送不上屏，故用「首帧是否 rasterize 过」这个不依赖 present 的
  /// 判据兜底。启动推进后置 null（只清一次 marker）。
  PresentWatchdog? _presentWatchdog;

  /// 守卫：Windows 安装器 handoff marker 只在拿到真实 Navigator 后 reconcile 一次。
  bool _windowsUpdateHandoffChecked = false;
  static bool get _isDesktop => Platform.isWindows;

  /// 热重载（debug）后丢弃设置 schema 缓存。schema 树按 locale 缓存，改
  /// `settings_schema_*.dart` 的树结构（增删项 / 改分区）不会改变 locale，缓存
  /// 命中会让热重载看不出效果；这里在每次 reassemble 时复位。仅 debug 触发。
  @override
  void reassemble() {
    super.reassemble();
    resetSettingsSchemaCache();
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);
    // BUG-772：仅 Windows 挂 present-watchdog——runApp 后 30s 仍无一帧 rasterize
    // （firstFrameRasterized==false）判定 raster/present 楔死（快速进出视频的
    // libmpv/ANGLE/WGC churn 污染进程共享 D3D device），落盘取证 + 一次性自动重启。
    // 这是 UI-isolate 看门狗（逃生 UI 同样送不上屏）够不着的 present 层兜底。
    if (Platform.isWindows) {
      _presentWatchdog = PresentWatchdog(
        timeout: _presentWatchdogTimeout,
        isFirstFrameRasterized: () =>
            WidgetsBinding.instance.firstFrameRasterized,
        onStall: _onPresentStall,
      )..arm();
    }
    // 桌面端监听原生窗口关闭：配合 main() 里的 setPreventClose(true)，在引擎拆除前
    // 停掉 Bonsoir mDNS 事件源（TODO-036）。
    if (_isDesktop) {
      windowManager.addListener(this);
    }
    // BUG-2259 的 macOS ⌘Q 退出落点已随平台裁剪删除；Windows 关闭路径见 onWindowClose。
    if (Platform.isWindows) {
      _systemThemeChannel.setMethodCallHandler(_handleSystemThemeChannel);
    }
    if (_isDesktop) {
      unawaited(_startCtlServer());
    }
    FushiToast.navigatorKey = ref.read(appProvider).navigatorKey;
    // 桌面 Mihon sidecar 是无头 JVM，被 Cloudflare 拦下时由宿主弹 WebView 解题。
    if (MihonRuntimeFactory.isSupported) {
      installMihonCloudflareResolver(ref.read(appProvider).navigatorKey);
    }
  }

  /// BUG-2459：引擎默认 deep linking 会把 `fushi://ankiFetch` 这类 x-callback
  /// 回跳再推成 `pushRouteInformation`，`WidgetsApp` 据此 `pushNamed('/')` 在
  /// 设置页上面又压一个 HomePage（用户看到「跳回主页」）。本 observer 在
  /// `WidgetsApp` 之前注册，先答 true 把这条推送截断；真正的 URL 处理仍由各平台
  /// 通道送进 [handleIncomingUrl]。理由与边界见 [swallowEngineDeepLinkRoute]。
  @override
  Future<bool> didPushRouteInformation(
    RouteInformation routeInformation,
  ) async {
    return swallowEngineDeepLinkRoute(routeInformation);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(appProvider).refreshSystemPalette();
      return;
    }
    // `detached` = the app is about to be terminated (the engine is detaching
    // from the view). Tear down Bonsoir's mDNS event sources here as a fallback
    // for platforms/paths that don't go through window_manager's onWindowClose.
    // Best-effort (the callback isn't awaited by the framework): the primary,
    // guaranteed path on desktop is [onWindowClose] under setPreventClose(true).
    if (state == AppLifecycleState.detached) {
      unawaited(_flushAndCloseForLifecycleDetach());
    }
  }

  /// 桌面原生窗口关闭信号（main() 已 setPreventClose(true) → 窗口不会自己关）。
  /// 退出期先切断 Bonsoir 事件源（TODO-036 防崩），flush 数据后 exit(0) 快杀，
  /// 不再同步拆引擎（TODO-086）。详见 [_flushAndExitForWindowClose]。
  @override
  void onWindowClose() async {
    await _flushAndExitForWindowClose();
  }

  @override
  void onWindowMoved() {
    DesktopWindowPlacement.rememberCurrentBounds();
  }

  @override
  void onWindowResized() {
    DesktopWindowPlacement.rememberCurrentBounds();
  }

  /// 最大化/还原直连记忆：Windows 上最大化不保证伴随 `onWindowResized`，只靠 resize
  /// 去抖会漏掉这个状态，下次冷启动就退回默认居中尺寸（用户「没记住窗口」）。
  @override
  void onWindowMaximize() {
    unawaited(DesktopWindowPlacement.rememberMaximized(true));
  }

  @override
  void onWindowUnmaximize() {
    unawaited(DesktopWindowPlacement.rememberMaximized(false));
    DesktopWindowPlacement.rememberCurrentBounds();
  }

  /// 桌面关闭快杀路径（TODO-086/BUG-191）。过去这里 await windowManager 的 destroy
  /// 触发原生 WM_DESTROY → 同步逐插件拆 Flutter 引擎（WebView2 / WGC 捕获 /
  /// libmpv），每个原生 teardown 几百 ms~秒级、串行叠加成几秒~十几秒卡死 UI 线程
  /// （用户「关闭要好久」）。改为：① 同步切断 Bonsoir 事件源（TODO-036 防崩）并把
  /// 原生 stop 后台化（根因B：Bonsoir 原生 stop 不归吃满超时）；② await flush 所有
  /// 活跃页面尚未落库的阅读位置/统计/观看时长（[ExitFlushRegistry]）；③ close
  /// database 做 WAL checkpoint，排空后台 isolate 的 pending 写——**这三步保证数据
  /// 完整性**；④ `exit(0)` 进程级终止，跳过 destroy() 的逐插件同步 teardown，由 OS
  /// 回收原生资源（WebView2/libmpv/socket），毫秒级返回。
  ///
  /// 不再调用 windowManager 的 destroy：exit(0) 是原子终止，没有「messenger 已拆但
  /// 进程仍在派发事件」的中间窗口，TODO-036 的崩溃前提随之消失。
  Future<void> _flushAndExitForWindowClose() async {
    if (_shutdownStarted) return;
    _shutdownStarted = true;
    final Stopwatch exitWatch = Stopwatch()..start();
    // BUG-3087：先让 Linux runner 进入「正在退出」，再隐藏窗口。此后二次启动不再
    // 交给本进程（文件会随进程一起丢、隐藏的窗口会被 present 回来），而是等本
    // 进程让出 D-Bus 名后自己按首实例启动。
    final AppModel appModel = ref.read(appProvider);
    try {
      await DesktopWindowPlacement.saveCurrentBoundsNow().timeout(
        const Duration(milliseconds: 800),
      );
    } catch (e) {
      debugPrint('[Fushi] desktop window placement save on exit failed: $e');
    }
    // ⓪' 几何已落盘 → 立刻把主窗从屏幕上摘掉。**用户感知的「关闭」到此为止**，后面
    //    的 flush / WAL checkpoint / 原生 teardown 都在看不见的窗口背后跑完。hide
    //    只是 ShowWindow(SW_HIDE)，不拆任何原生资源，不会把 ④ 的 WebView2 成本提前。
    //    必须排在 saveCurrentBoundsNow 之后：窗口隐藏后再读几何不可信。
    try {
      await windowManager.hide().timeout(const Duration(milliseconds: 300));
    } catch (e) {
      debugPrint('[Fushi] hide on exit failed: $e');
    }
    // 退出总预算看门狗。下面每步各有超时，但 ③ 的关库（内含下载管线收尾等待）与 ④
    // 的原生 WebView2 / DirectComposition teardown 历史上都出现过不归（BUG-192）。
    // 窗口此刻已不可见，进程再卡住就成了用户看不见也关不掉的僵尸——到点无条件终止。
    final Timer exitWatchdog = Timer(_exitWatchdogTimeout, () {
      debugPrint(
        '[Fushi] exit watchdog fired after '
        '${exitWatch.elapsedMilliseconds}ms; forcing exit',
      );
      exit(0);
    });
    // ①② 并行：切断 Bonsoir 事件源只动 mDNS 订阅，页面 flush 只写 Drift，两者互不
    //    依赖。过去串行 await 让各自的超时预算直接相加。
    await Future.wait(<Future<void>>[
      // ② flush 活跃页面 pending 进度/统计（缓存值落库，不碰退出期正在拆的 WebView）。
      _guardedExitStep('exit flush', () async {
        await ExitFlushRegistry.instance.flushAll();
      }),
      // 删掉 CLI 发现文件：exit(0) 之后不会再有 dispose，不删就留下一份残留
      // （CLI 能认出残留，但少一次连不上的探测）。
      _guardedExitStep('ctl channel stop', () async {
        await _ctlServer?.stop().timeout(const Duration(milliseconds: 500));
      }),
    ]);
    // ③ close database：WAL checkpoint + 排空后台 isolate pending 写。退出最后一道
    //    数据完整性闸门——必须在 exit(0) 之前完成。
    //    加超时上界：quiesceBackgroundDatabaseWriters 内部要等在飞的下载任务收尾，
    //    这里过去是整条退出链上唯一的无界等待。WAL 本身崩溃安全，超时放行只损失一次
    //    checkpoint（下次启动自动回放），不损失任何已提交的数据。
    await _guardedExitStep('database close', () async {
      // 上界只在**这条**退出链上给：迁移导入 / 备份导入 / 数据根迁移也调
      // closeDatabase()，它们关库后要在文件层动整个 DB 目录，放行一个仍在飞的
      // `_process` 是数据安全问题（BUG-1505）。退出路径不同——进程马上就没了。
      await appModel.closeDatabase().timeout(_closeDatabaseOnExitTimeout);
    });
    debugPrint(
      '[Fushi] exit teardown finished in ${exitWatch.elapsedMilliseconds}ms',
    );
    // ④ 进程级快杀（desktop lifecycle = exit(0)），跳过 destroy() 的同步插件拆除。
    //
    // **看门狗不在这之前 cancel**：exitApp() 里 WindowsNativePreExit + exit(0) 才是
    // 历史上最会不归的一步（原生 WebView2 / DirectComposition 同步析构），而窗口此刻
    // 已经 hide 掉，卡在这里就是「用户看不见也关不掉的僵尸」。exit(0) 一旦生效，
    // 这个 Timer 根本没机会跑；真走到下面说明 exitApp 没杀掉进程，那正是要它兜底的
    // 场景。cancel 放在最后，只为「万一 exitApp 返回了」留一个显式的收口点。
    await appModel.platformServices.lifecycle.exitApp();
    exitWatchdog.cancel();
  }

  /// 退出期单步执行器：统一吞掉超时/异常 + 耗时埋点。退出清理失败绝不阻止退出，但
  /// 也绝不静默——每步耗时都打出来，下次再遇「关闭慢」可直接读日志定位到具体哪一步。
  Future<void> _guardedExitStep(
    String label,
    Future<void> Function() run,
  ) async {
    final Stopwatch watch = Stopwatch()..start();
    try {
      await run();
    } on TimeoutException {
      debugPrint(
        '[Fushi] exit step "$label" timed out after '
        '${watch.elapsedMilliseconds}ms; continuing',
      );
      return;
    } catch (e) {
      debugPrint(
        '[Fushi] exit step "$label" failed after '
        '${watch.elapsedMilliseconds}ms: $e',
      );
      return;
    }
    debugPrint(
      '[Fushi] exit step "$label" took ${watch.elapsedMilliseconds}ms',
    );
  }

  /// 停掉 Bonsoir 的 LAN 广播 + 发现（mDNS 事件源），再 flush 活跃页面并 close DB。
  ///
  /// 仅作非 Android 的 `detached` 生命周期兜底。Android view 脱离不代表引擎退出。桌面
  /// 点 X 走 [_flushAndExitForWindowClose]（flush + closeDB + exit(0)），不再到这里。
  /// 超时上限收紧到 1.5s（TODO-086）：原生 stop 不归时放行，避免拖住退出。
  Future<void> _flushAndCloseForLifecycleDetach() async {
    if (_shutdownStarted) return;
    _shutdownStarted = true;
    final AppModel appModel = ref.read(appProvider);

    try {
      await ExitFlushRegistry.instance.flushAll();
    } catch (e) {
      debugPrint('[Fushi] lifecycle detach flush failed: $e');
    }

    try {
      await appModel.closeDatabase();
    } catch (e) {
      debugPrint('[Fushi] database close on lifecycle detach failed: $e');
    }
  }

  @override
  void dispose() {
    _systemColorRefreshDebounce?.cancel();
    _loadingWatchdog?.cancel();
    unawaited(_ctlServer?.stop());
    _ctlServer = null;
    if (_isDesktop) {
      windowManager.removeListener(this);
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<bool> handleIncomingUrl({
    required String? data,
    required bool isInitial,
  }) async {
    if (data == null || !mounted) return false;
    // my-comic：仅保留 Manga 书架长按图标快捷方式。查词 / 配对 / Anki 回跳 /
    // 云同步 OAuth / 卡片来源等非漫画深链入口已随对应域移除。
    final AppShortcut? shortcut = AppShortcut.tryParse(data);
    if (shortcut != null) {
      _queueAppShortcut(shortcut);
      return true;
    }
    return false;
  }

  void _queueAppShortcut(AppShortcut shortcut) {
    final bool ready = mounted && ref.read(appProvider).isInitialised;
    _appShortcuts.enqueue(shortcut, ready: ready);
    // 未初始化：初始化完成后的根 build 会调 [AppShortcutQueue.schedule]。
    if (mounted && !ready) setState(() {});
  }

  Future<void> _runAppShortcut(AppShortcut shortcut) {
    final AppModel appModel = ref.read(appProvider);
    return runAppShortcut(
      shortcut,
      visibility: appModel.moduleVisibility,
      // 有效完成状态：新装用户（first_time_setup=true 且未完成）等同「引导中」，
      // 快捷方式只切 tab；已有用户（first_time_setup=false）不因新偏好缺省 false
      // 被误当成引导中。
      onboardingCompleted: !appModel.needsOnboarding,
      navigator: appModel.navigatorKey.currentState,
      selectHomeTab: (HomeTab tab) => homeShellTabNotifier.value = tab,
    );
  }

  /// 启动桌面本机控制通道：`fushi_cli` 经 127.0.0.1 + token 驱动本 app。
  ///
  /// 在 initState 就开（不等初始化完成）：CLI 拉起 app 后靠它判断「进程已起、还在
  /// 初始化」，`status` 回 `initialised:false`，open / lookup 回 409 让 CLI 继续等。
  Future<void> _startCtlServer() async {
    final CtlServer? server = await startDesktopCtlServer(
      DesktopCtlHost(
        isReady: () {
          final AppModel model = ref.read(appProvider);
          return model.isInitialised && model.navigatorKey.currentState != null;
        },
        appVersion: () => ref.read(appProvider).packageInfo.version,
        // my-comic：命令行控制通道不再提供外部视频 / 查词 / 非漫画路由入口。
        openTarget: (String _) async =>
            const CtlOpenResult.rejected('my-comic 只支持漫画库'),
        lookupWord: (String _) async {},
        quitApp: _flushAndExitForWindowClose,
        routes: const [],
      ),
    );
    if (!mounted) {
      await server?.stop();
      return;
    }
    _ctlServer = server;
  }

  /// TODO-1092: Windows runner 报告「系统强调色/主题色已变」。经短去抖合并同一次
  /// 变更连发的多条广播，然后调 [AppModel.refreshSystemPalette] 让 `system-theme`
  /// 动态取色实时更新——修复「必须最小化/恢复/失焦触发生命周期 resumed 才刷新」。
  /// 与 [didChangeAppLifecycleState] 的 resumed 刷新共存：两者都只是重新取系统色，
  /// 幂等、互不冲突。
  Future<dynamic> _handleSystemThemeChannel(MethodCall call) async {
    if (call.method != 'onSystemColorChanged') return null;
    _systemColorRefreshDebounce?.cancel();
    _systemColorRefreshDebounce = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      unawaited(ref.read(appProvider).refreshSystemPalette());
    });
    return null;
  }

  void _scheduleWindowsUpdateHandoffReconcile() {
    if (_windowsUpdateHandoffScheduled || _windowsUpdateHandoffChecked) {
      return;
    }
    _windowsUpdateHandoffScheduled = true;
    final String currentVersion = appModel.packageInfo.version;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _windowsUpdateHandoffScheduled = false;
      if (!mounted || _windowsUpdateHandoffChecked) return;
      final BuildContext? navigatorContext =
          appModel.navigatorKey.currentContext;
      if (navigatorContext == null ||
          !UpdateChecker.canShowDialogFromContext(navigatorContext)) {
        debugPrint(
          '[Fushi] windows update handoff reconcile deferred: '
          'navigator context unavailable',
        );
        return;
      }
      _windowsUpdateHandoffChecked = true;
      // Windows 与 macOS 运行时互斥；两个 reconcile 各自按平台自守（非本平台即早退），
      // 故并列调用只会有一个真正执行。共用同一 checked 旗标做一次性去重。
      unawaited(
        UpdateChecker.reconcilePendingWindowsInstallerHandoff(
          navigatorContext,
          currentVersion,
        ),
      );
      unawaited(
        UpdateChecker.reconcilePendingMacInstallerHandoff(
          navigatorContext,
          currentVersion,
        ),
      );
    });
  }

  /// TODO-1260：进入裸加载态时启动看门狗（只挂一个；已翻超时标记则不再重启）。
  void _startLoadingWatchdogIfNeeded() {
    if (_loadingWatchdog != null || _loadingTimedOut) return;
    _loadingWatchdog = Timer(_loadingWatchdogTimeout, () {
      if (mounted) setState(() => _loadingTimedOut = true);
    });
  }

  /// TODO-1260：离开裸加载态（初始化完成 / 落错误屏 / 迁移 / 备份导入遮罩）或用户手动
  /// 重试时取消看门狗并复位，让下一轮加载重新计时、避免过时 timer 空转触发无用 setState。
  void _cancelLoadingWatchdog() {
    _loadingWatchdog?.cancel();
    _loadingWatchdog = null;
    _loadingTimedOut = false;
  }

  /// 首帧释放 + 显窗是一次性的：`allowFirstFrame()` 只能对应一次 `deferFirstFrame()`，
  /// 所以失败后不复位调度标志（重调度会二次 allow 触发断言），而是直接兜底显窗——
  /// runner 普通启动隐藏建窗，这里不显窗进程就永远不可见。
  void _scheduleStartupFrameRelease() {
    if (!_deferStartupFrame || _startupFrameReleaseScheduled) {
      return;
    }
    _startupFrameReleaseScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_releaseStartupFrame());
    });
  }

  Future<void> _releaseStartupFrame() async {
    final WidgetsBinding binding = WidgetsBinding.instance;
    bool firstFrameAllowed = false;
    try {
      binding.allowFirstFrame();
      firstFrameAllowed = true;
      await binding.waitUntilFirstFrameRasterized;
      if (!mounted) return;
      await _revealStartupWindow();
    } catch (e) {
      debugPrint('[Fushi] startup presentation release failed: $e');
      if (!firstFrameAllowed) {
        try {
          binding.allowFirstFrame();
        } catch (e) {
          debugPrint('[Fushi] startup first frame fallback failed: $e');
        }
      }
      await _revealStartupWindowFallback();
    }
    if (mounted) {
      setState(() => _initialThemePresented = true);
    }
  }

  /// 隐藏建窗的唯一显窗点（含迁移后自动重启的新进程，TODO-959）：首帧光栅化后
  /// show + focus 抢回前台。
  Future<void> _revealStartupWindow() async {
    await windowManager.show();
    try {
      await windowManager.focus();
    } catch (e) {
      debugPrint('[Fushi] startup window focus skipped: $e');
    }
  }

  Future<void> _revealStartupWindowFallback() async {
    try {
      await _revealStartupWindow();
    } catch (e) {
      debugPrint('[Fushi] startup window fallback show failed: $e');
    }
  }

  void _scheduleInitialThemeAnimationRestore() {
    if (_deferStartupFrame ||
        _initialThemePresented ||
        _initialThemeRestoreScheduled) {
      return;
    }
    _initialThemeRestoreScheduled = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialThemeRestoreScheduled = false;
      if (!mounted || _initialThemePresented) return;
      setState(() => _initialThemePresented = true);
    });
  }

  /// BUG-772：present 楔死自愈动作（仅 Windows）——落盘取证 + 一次性自动重启。marker 不
  /// 存在（首次楔死）→ 认领并 restartApp（有验证过的桌面重启路径）；已存在（上次重启后
  /// 仍卡，疑驱动级 device-lost 跨进程）→ 不再重启，避免无限循环，取证已落盘供下次上传。
  /// restartApp 走 platform 线程起新进程 + 退本进程，不依赖已楔死的 raster 线程。
  void _onPresentStall() {
    final File? logFile = PresentStallLog.resolveStallLogFile();
    if (logFile != null) {
      PresentStallLog.appendStall(
        logFile,
        DateTime.now(),
        afterTimeout: _presentWatchdogTimeout,
      );
    }
    final File? marker = PresentStallLog.resolveMarkerFile();
    if (marker != null && PresentStallLog.claimRestart(marker)) {
      unawaited(ref.read(appProvider).platformServices.lifecycle.restartApp());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (appModel.isInitialised ||
        appModel.initError != null ||
        appModel.dataRootUnavailable != null ||
        _loadingTimedOut) {
      // Release the held first frame after the home page or error UI is built.
      _scheduleStartupFrameRelease();
    }
    // TODO-1260：只要不再处于「裸加载」态（已初始化 / 已落错误屏 / 迁移或备份导入有自己
    // 的进度遮罩），就撤掉加载看门狗，避免它在这些态里事后空转触发一次无用重建。
    if (appModel.isInitialised || appModel.initError != null) {
      _cancelLoadingWatchdog();
      // BUG-772：启动已推进（首帧早已 rasterize）→ 撤 present-watchdog 并清自动重启
      // marker（只跑一次：置 null 后不再进），让下次再遇 present 楔死还能自动重启一次。
      if (_presentWatchdog != null) {
        _presentWatchdog!.disarm();
        _presentWatchdog = null;
        final File? marker = PresentStallLog.resolveMarkerFile();
        if (marker != null) PresentStallLog.clearRestartMarker(marker);
      }
    }
    // Fields like locales/theme are late and only available after
    // initialise() completes. Keep the platform startup surface visible while
    // this minimal loading surface is built; do not present it as the first frame.
    //
    // Use system brightness to match the native splash and avoid a white
    // flash when the user has dark mode enabled.
    // Downgrade protection: the on-disk DB was created by a newer build. Show a
    // dedicated, NON-retryable "update your app" notice (no Retry button —
    // retrying re-runs init and fails identically; the DB is intentionally left
    // untouched). Checked BEFORE the generic init-error screen.
    final downgrade = appModel.downgradeError;
    // 最低 schema 门槛：库比本版本能升级的下限还老（或只有改名前的 hibiki.db）。
    // 与降级同一块非重试专屏，只是文案换成「先装桥接版本打开一次，再更新」。
    final legacySchema = appModel.legacySchemaError;
    if (downgrade != null || legacySchema != null) {
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      final ThemeData fallbackTheme = buildFushiFallbackTheme(brightness);
      final ColorScheme cs = fallbackTheme.colorScheme;
      return TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: fallbackTheme,
          home: Scaffold(
            backgroundColor: _savedSplashColor ?? cs.surface,
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FushiIcon(Icons.system_update, size: 48, color: cs.primary),
                    const SizedBox(height: 16),
                    Text(
                      downgrade != null
                          ? t.db_downgrade_title
                          : t.db_legacy_schema_title,
                      style: fallbackTheme.textTheme.titleLarge?.copyWith(
                        color: cs.onSurface,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      downgrade != null
                          ? t.db_downgrade_message(
                              dbVersion: downgrade.dbVersion,
                              appVersion: downgrade.appSchemaVersion,
                            )
                          : t.db_legacy_schema_message(
                              version: kLegacySchemaBridgeAppVersion,
                              url: kLegacySchemaBridgeReleaseUrl,
                            ),
                      style: fallbackTheme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    // 门槛提示给出可执行出口：直接打开桥接版本的 Release 页。
                    if (downgrade == null) ...[
                      const SizedBox(height: 20),
                      FushiFilledButton.icon(
                        icon: const FushiIcon(FushiIcons.openInNew, size: 18),
                        label: Text(
                          t.db_legacy_schema_release_open(
                            version: kLegacySchemaBridgeAppVersion,
                          ),
                        ),
                        onPressed: () => launchUrl(
                          Uri.parse(kLegacySchemaBridgeReleaseUrl),
                          mode: LaunchMode.externalApplication,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    // TODO-905: the DB could not be opened even after WAL/sidecar recovery —
    // the main fushi.db is corrupt. Show an actionable notice (the recovery
    // ladder already ran inside the open path, so a plain Retry would loop
    // forever against the same un-openable file). Checked BEFORE the generic
    // init-error screen so the user gets the corrupt-DB guidance, not a raw
    // "disk I/O error" with a dead Retry loop.
    final unrecoverable = appModel.unrecoverableDbError;
    if (unrecoverable != null) {
      // BUG-1899：「打不开」不是「坏了」。父目录不存在 / 无权限 / 只读介质 / 盘断链
      // 都会让 sqlite 报 SQLITE_CANTOPEN(14)，此前它们共用「数据库损坏，请恢复备份或
      // 清空数据」这句话——在磁盘完好的情况下把用户往清空数据上引。
      final bool cannotOpen =
          unrecoverable.kind == FushiDatabaseFailureKind.cannotOpen;
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      final ThemeData fallbackTheme = buildFushiFallbackTheme(brightness);
      final ColorScheme cs = fallbackTheme.colorScheme;
      return TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: fallbackTheme,
          home: Scaffold(
            backgroundColor: _savedSplashColor ?? cs.surface,
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FushiIcon(
                      cannotOpen
                          ? Icons.folder_off_outlined
                          : Icons.broken_image_outlined,
                      size: 48,
                      color: cs.error,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      cannotOpen
                          ? t.db_cannot_open_title
                          : t.db_unrecoverable_title,
                      style: fallbackTheme.textTheme.titleLarge?.copyWith(
                        color: cs.onSurface,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      cannotOpen
                          ? t.db_cannot_open_message
                          : t.db_unrecoverable_message,
                      style: fallbackTheme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    SelectableText(
                      appModel.initError!,
                      style: fallbackTheme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    // BUG-815: a custom data location IS configured on desktop but is currently
    // unreachable (slow/sleeping/disconnected drive). AppPaths.resolve threw
    // instead of SILENTLY opening the empty default location — that empty view
    // reads as catastrophic data loss even though the real data sits untouched
    // on the configured drive, and any content created in that empty session
    // would land in the WRONG place. Show a dedicated escape screen that NEVER
    // presents empty-as-real: default action is Retry (re-probe → use the real
    // DB once the drive wakes); an explicit, clearly-worded second button lets
    // the user consciously start with the default location (their data is NOT
    // touched) for the drive-truly-gone case. Checked BEFORE the loading branch.
    final dataRootUnavailable = appModel.dataRootUnavailable;
    if (dataRootUnavailable != null) {
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      final ThemeData fallbackTheme = buildFushiFallbackTheme(brightness);
      final ColorScheme cs = fallbackTheme.colorScheme;
      return TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: fallbackTheme,
          home: Scaffold(
            backgroundColor: _savedSplashColor ?? cs.surface,
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FushiIcon(
                      Icons.folder_off_outlined,
                      size: 48,
                      color: cs.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      t.data_root_unavailable_title,
                      style: fallbackTheme.textTheme.titleLarge?.copyWith(
                        color: cs.onSurface,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      t.data_root_unavailable_message(
                        path: dataRootUnavailable.configuredPath,
                      ),
                      style: fallbackTheme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        FushiFilledButton.icon(
                          icon: const FushiIcon(Icons.refresh, size: 18),
                          label: Text(t.retry),
                          onPressed: () => appModel.retryInitialise(),
                        ),
                        FushiOutlinedButton.icon(
                          icon: const FushiIcon(Icons.folder_open, size: 18),
                          label: Text(t.data_root_use_default_button),
                          onPressed: () =>
                              appModel.retryInitialiseWithDefaultRoot(),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (appModel.initError != null) {
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      final ThemeData fallbackTheme = buildFushiFallbackTheme(brightness);
      final ColorScheme cs = fallbackTheme.colorScheme;
      return TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: fallbackTheme,
          home: Scaffold(
            backgroundColor: _savedSplashColor ?? cs.surface,
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FushiIcon(Icons.error_outline, size: 48, color: cs.error),
                    const SizedBox(height: 16),
                    Text(
                      t.initialization_failed,
                      style: fallbackTheme.textTheme.titleLarge?.copyWith(
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SelectableText(
                      appModel.initError!,
                      style: fallbackTheme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                      selectionControls: FushiTextSelectionControls(
                        shareAction: (text) => FushiShare.shareText(text),
                        allowCopy: true,
                        allowCut: false,
                        allowPaste: false,
                        allowSelectAll: true,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        FushiFilledButton.icon(
                          icon: const FushiIcon(Icons.refresh, size: 18),
                          label: Text(t.retry),
                          onPressed: () => appModel.retryInitialise(),
                        ),
                        FushiOutlinedButton.icon(
                          icon: const FushiIcon(Icons.copy, size: 18),
                          label: Text(t.copy_error),
                          onPressed: () {
                            Clipboard.setData(
                              ClipboardData(text: appModel.initError!),
                            );
                            FushiToast.show(
                              msg: t.error_copied,
                              severity: ToastSeverity.success,
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    // 旧 data-root 整目录迁移遮罩已随迁移器删除（ticket 12）；切换 Content root
    // 只创建空目录并在设置页提示，不再进入全局迁移态。
    // my-comic：Fushi `.fushi.zip` 备份导入/恢复路径已移除（ticket 05）。
    if (!appModel.isInitialised) {
      // TODO-1260：进入裸加载态即挂看门狗；超时前显示转圈，超时后显示逃生 UI。
      _startLoadingWatchdogIfNeeded();
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      final ThemeData fallbackTheme = buildFushiFallbackTheme(brightness);
      final ColorScheme cs = fallbackTheme.colorScheme;
      return TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: fallbackTheme,
          home: Scaffold(
            backgroundColor: _savedSplashColor ?? cs.surface,
            body: LoadingWatchdogView(
              timedOut: _loadingTimedOut,
              colorScheme: cs,
              onRetry: () {
                // 复位看门狗，让重试触发的新一轮加载重新计时。retryInitialise 先退回
                // 默认根（Layer 1 的 2s 超时降级）再重跑 init，通常即成功。
                _cancelLoadingWatchdog();
                appModel.retryInitialise();
              },
            ),
          ),
        ),
      );
    }

    _appShortcuts.schedule();
    // 长按图标菜单跟着模块开关与界面语言走：两者一变根 build 就重跑（模块开关
    // notifyListeners / 语言切换重建整树），发布器按签名去重，平时不过通道。
    AppShortcutsPublisher.instance.sync(
      AppShortcut.available(appModel.moduleVisibility),
      labelOf: (AppShortcut shortcut) => homeNavItemFor(shortcut.homeTab).label,
      disabledMessage: t.module_disabled_hint,
    );

    // TODO-960: live UI-language switch on desktop. [setAppLocale] no longer
    // restarts the process there (it raced the Windows single-instance mutex
    // and killed the app); it mutates [LocaleSettings] + notifyListeners
    // instead. Most of the UI reads the global Method A `t`, which does NOT
    // rebuild on a [LocaleSettings] change on its own, so this locale-keyed
    // [KeyedSubtree] remounts the whole app subtree whenever the display
    // language changes, forcing every widget (incl. global-`t` readers) to
    // re-resolve its strings. (The generated [TranslationProvider] takes no
    // `key`, so the key lives on the enclosing [KeyedSubtree].) The remount
    // returns to [home]; this is acceptable (a real restart also dropped the
    // navigation stack) and only fires on an explicit language change, not on
    // ordinary [notifyListeners] ticks.
    _scheduleInitialThemeAnimationRestore();
    final ThemeData lightTheme = appModel.theme;
    final ThemeData darkTheme = appModel.darkTheme;
    return KeyedSubtree(
      key: ValueKey<String>('app-locale-${locale.toLanguageTag()}'),
      child: TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: appModel.navigatorKey,
          // Resets the focus highlight to touch on every route push/pop so a ring
          // lit by keyboard/gamepad navigation on one page is not carried onto the
          // freshly-entered page (BUG-398).
          navigatorObservers: <NavigatorObserver>[
            appModel.focusHighlightObserver,
          ],
          home: home,
          locale: locale,
          // material_ui 的 delegates 已含 Cupertino + Widgets 三份本地化。
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: appModel.locales.values,
          themeMode: themeMode,
          theme: lightTheme,
          darkTheme: darkTheme,
          // 桌面端自动滚动条：外观不变，按偏一点也能抓住拇指拖、点轨道不再
          // 整页乱跳（见 FushiScrollBehavior）。
          scrollBehavior: const FushiScrollBehavior(),
          // 启动首帧从 fallback 主题切到持久化主题时不做过渡；首帧呈现后恢复
          // 正常的主题交叉过渡。墨水屏下始终关闭（中间灰帧每帧一次局部刷新）。
          themeAnimationStyle:
              (!_initialThemePresented || appModel.themeNotifier.einkMode)
              ? AnimationStyle.noAnimation
              : fushiThemeAnimationStyle,
          // This is responsible for the initialising the global spacing across
          // the entire project, making use of the [spaces] package.
          builder: (context, child) {
            final cs = Theme.of(context).colorScheme;
            // 推给原生窗口的颜色一律取**目标**主题，而不是 builder 所在
            // AnimatedTheme 里逐帧插值出来的过渡主题（BUG 见下方 setCaptionColors
            // 注释）：主题交叉过渡 280ms 内 builder 每帧重跑，插值色每帧都不同，
            // 原生侧每次都 DwmSetWindowAttribute + FillSurfaceBackdrop 整窗铺底，
            // 切主题 / 切深色时整页连闪十几下。
            final ThemeData settledTheme = fushiSettledTheme(
              themeMode: themeMode,
              platformBrightness: MediaQuery.platformBrightnessOf(context),
              light: lightTheme,
              dark: darkTheme,
            );
            final ColorScheme settled = settledTheme.colorScheme;
            // BUG-1916: this is no longer about the *caption* — the Windows
            // native caption is hidden for good (see main()), and the themed
            // native title bar this call used to feed was correctly deleted
            // with it (`3c4a5960f8`). The same channel now also drives the
            // runner's own window-surface backdrop brush
            // (`FlutterWindow::ApplyCaptionColors` → `Win32Window::
            // SetBackdropColor`), and that surface is very much alive: DWM
            // animates it — not the Flutter view's composition layer — during
            // maximize / restore / DPI transitions, so whatever colour it holds
            // shows for a frame. Without this push the brush stays at the
            // TODO-959 cold-start splash teal forever and every maximize flashes
            // it (measured 100% of the window at +43ms). Hence: pushed
            // unconditionally, not behind a title-bar capability check — the
            // DwmSetWindowAttribute half is a harmless no-op under a hidden
            // caption, and the channel de-dupes identical values, so this is
            // cheap per rebuild. Guarded by
            // `test/build/win_resize_backdrop_guard_test.dart` (the native chain
            // is only as good as what Dart feeds it).
            WindowCaptionChannel.setCaptionColors(
              caption: settled.surface,
              text: settled.onSurface,
            );
            // Glass design system: ask for the system window material (Windows
            // 11 Mica via the runner, macOS NSVisualEffectView vibrancy). The
            // home shell only turns translucent once the platform reports
            // success (`systemBackdropActive`), so Win10 / others stay solid.
            // Decoupled from the component surface material on purpose
            // (owner decision 2026-10-13): Apple floating surfaces are solid
            // (glass material pinned to off) but the window-level Mica /
            // vibrancy stays — so this asks the design system + reduce
            // transparency + high contrast, never `glassMaterialOf`.
            // Guarded by `test/widgets/window_backdrop_decoupling_test.dart`.
            WindowCaptionChannel.setSystemBackdrop(
              mica: windowBackdropRequestedOf(context),
              dark: settled.brightness == Brightness.dark,
            );
            // Drive the status/navigation bar icon brightness from the *live*
            // theme so switching themes repaints the system bars. The builder
            // reruns on every theme change, so the AnnotatedRegion re-emits the
            // matching overlay style.
            // BUG-1619：整棵 app 焦点树的闸门——主窗不在前台时任何 requestFocus
            // 都不生效，杜绝「Dart 请求焦点 → 引擎 SetFocus(FlutterView) → Win32
            // 连带激活主窗」把主界面抢到用户的游戏 / 浏览器前面。见
            // [MainWindowFocusGate] 的完整推导。
            final Widget gated = MainWindowFocusGate(
              child: AnnotatedRegion<SystemUiOverlayStyle>(
                value: fushiSystemOverlayStyle(cs.brightness),
                child: CupertinoTheme(
                  data: fushiCupertinoTheme(
                    cs,
                    fontFamily: appModel.appFontFamily,
                  ),
                  // 玻璃设计系统的组件配色 / 渲染档位作用域（结构恒定，
                  // 见 FushiGlassScope 类注释）。
                  // LegacyDesignCompatibility：把新 material_ui / cupertino_ui
                  // 主题与本地化桥给仍用 SDK 旧 Material / Cupertino 的第三方
                  // 组件（必须在上面这层 CupertinoTheme 之内）。
                  child: LegacyDesignCompatibility(
                    child: FushiGlassScope(
                      child: LayoutBuilder(
                        builder: (BuildContext context, BoxConstraints constraints) {
                          final Size viewport =
                              constraints.hasBoundedWidth &&
                                  constraints.hasBoundedHeight
                              ? constraints.biggest
                              : MediaQuery.sizeOf(context);
                          final double uiScale = appModel
                              .resolveAppUiScaleForViewport(
                                viewport: viewport,
                                platform: Theme.of(context).platform,
                              );
                          Widget navigation = wrapWithGlobalNavigation(
                            navigatorKey: appModel.navigatorKey,
                            focusNavigationEnabled:
                                appModel.experimentalFocusNavigationEnabled,
                            registry: appModel.shortcutRegistry,

                            // BUG-1349（第二处根因）：焦点导航层（FushiFocusRoot 的
                            // fallbackNode）必须在全局导航层**之内**。键事件沿焦点树
                            // 冒泡：fallbackNode 若在 wrapWithGlobalNavigation 之外，
                            // 零受管目标页把焦点回收到兜底节点后，Esc/全局快捷键根本
                            // 到不了全局处理器——整个全局键处理静默失效。
                            child: _wrapFocusNavigation(
                              enabled:
                                  appModel.experimentalFocusNavigationEnabled,
                              // TODO-354 ①：常驻悬浮字幕查词宿主覆盖在导航之上，让书架/
                              // 首页开的悬浮字幕（无 reader）点词也能在主窗口弹查词。无
                              // 挂起请求时整层 IgnorePointer 透传，不抢任何页面的命中测试。
                              // 全局悬浮球（docs/specs/2026-09-28-floating-ball.md）
                              // 在查词宿主之下：球点出的查词弹窗要盖在球上。
                              child: child!,
                            ),
                          );
                          navigation = FushiAppUiScale(
                            scale: uiScale,
                            child: navigation,
                          );
                          // 自绘顶栏的唯一门控就是这条启动闩（Windows / macOS 由
                          // `main()` 置位）：不再叠一层 `Platform.isWindows`，否则
                          // macOS 明明已经隐藏了系统标题栏与交通灯，却拿不到替代顶栏
                          // ——窗口既没有标题也没有最小化/关闭按钮。
                          if (FushiDesktopTitleBar.isEnabled) {
                            navigation = ListenableBuilder(
                              // The home rail is only on screen while the home
                              // shell is the top route; opening a media item
                              // covers it — the same signal the macOS shell uses
                              // to drop its sidebar — so the title has to
                              // un-indent with it. `navigation` is passed through
                              // as the unchanging `child`, so flipping this never
                              // rebuilds the navigator subtree.
                              listenable: Listenable.merge(<Listenable>[
                                appModel.mediaOpenNotifier,
                                appModel.navRailExpandedNotifier,
                              ]),
                              builder: (BuildContext context, Widget? child) {
                                final bool mediaOpen =
                                    appModel.mediaOpenNotifier.value;
                                final WindowSizeClass sizeClass =
                                    windowSizeClassForWidth(viewport.width);
                                final bool railVisible =
                                    !mediaOpen &&
                                    sizeClass != WindowSizeClass.compact;
                                // 展开侧栏（玻璃 208 悬浮侧栏 / MD3 220 展开
                                // rail）与收起 rail 宽度不同，标题跟着它缩进；
                                // 展开态与首页 rail 同一判据（尺寸档 + MD3 菜单钮
                                // 手动切换的记忆）。
                                final double railWidth =
                                    adaptiveNavRailWidthFor(
                                      context,
                                      extended: adaptiveNavRailExtended(
                                        context,
                                        sizeClass: sizeClass,
                                        userExpanded: appModel
                                            .navRailExpandedNotifier
                                            .value,
                                      ),
                                    );
                                return FushiDesktopTitleBar(
                                  // The native-sized frame sits outside app UI
                                  // zoom; align its title with the visually scaled
                                  // home rail. Breakpoint and rail width both come
                                  // from the widgets that own them (HomePage's
                                  // size class / adaptiveNavRail), so they cannot
                                  // drift apart behind a copied literal.
                                  leadingInset: railVisible
                                      ? railWidth * uiScale
                                      : 0,
                                  title: ValueListenableBuilder<HomeTab>(
                                    valueListenable: homeShellTabNotifier,
                                    builder:
                                        (
                                          BuildContext context,
                                          HomeTab tab,
                                          Widget? _,
                                        ) {
                                          return Text(
                                            homeNavItemFor(tab).label,
                                          );
                                        },
                                  ),
                                  child: child!,
                                );
                              },
                              child: navigation,
                            );
                          }
                          return navigation;
                        },
                      ),
                    ),
                  ),
                ),
              ),
            );
            // BUG-2834：全 app 鼠标滚轮无极滚动，一处接住所有滚动区。
            return SmoothWheelScrollScope(child: gated);
          },
        ),
      ),
    );
  }

  /// Responsible for managing global app-wide state.
  AppModel get appModel => ref.watch(appProvider);

  /// The application will open to this page upon startup.
  ///
  /// 全局「下载完成后加入书架？」提示挂在主界面根部：非书架下载可以在作品页
  /// 之外完成（下载页重试 / 后台队列），提示不能依赖作品页是否打开。
  Widget get home => const MangaAddToShelfPromptHost(child: HomePage());

  ThemeMode get themeMode => appModel.themeMode;

  /// The current app chrome locale, dependent on the display language.
  Locale get locale => appModel.appLocale;
}

/// 焦点导航层（[FushiFocusRoot] 焦点控制器 + [FushiFocusRing] 可见焦点环）
/// **恒定挂载，行为按实验开关门控**。禁用时 [FushiFocusRoot.maybeControllerOf]
/// 返回 null（各组件据此走原生焦点遍历，语义与「未包裹」时代逐字节一致）、
/// 焦点环不绘制。
///
/// **挂载位置纪律（BUG-1349）**：本层必须位于 [wrapWithGlobalNavigation]
/// **之内**——fallbackNode 是可聚焦节点，键事件沿焦点树只向祖先冒泡；挂在全局
/// 导航层之外时，零受管目标页把焦点回收到兜底节点后，Esc / 全局快捷键全部
/// 到不了全局处理器（详情页 Esc 失效正是此故障 + escape 解析遮蔽的叠加）。
///
/// 用户实报（2026-07-22）：旧实现按开关插/拔这两层——切「键盘/手柄焦点导航」
/// 开关时整棵 app 子树因结构变化被重挂载，被切的 Switch 以新状态直接 mount，
/// 滑块动画消失（其余开关都有动画）。结构恒定后 Element 全保留，动画回归，
/// 顺带不再丢各页滚动位置。
Widget _wrapFocusNavigation({required bool enabled, required Widget child}) {
  return FushiFocusRoot(
    enabled: enabled,
    child: FushiFocusRing(enabled: enabled, child: child),
  );
}
