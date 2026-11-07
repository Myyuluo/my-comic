import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/src/startup/test_environment.dart';
import 'package:fushi/src/storage/content_root_validation.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 应用存储根的**唯一入口**。
///
/// 存储按生命周期拆成两个根（ADR 0011）：
///   - **Content root（内容根）**：用户可见的漫画内容。默认
///     `<Documents>/MyComic`，下设 `downloads`、`autobackup`、`localcomic`。
///     卸载/更新不触碰它。
///   - **Program state root（程序状态根）**：随程序目录存放的应用状态。默认
///     `<exeDir>/userdata`，下设 `state`（DB、prefs、Mihon runtime、更新包、自定义
///     字体、WebView2 数据、日志等）与 `cache`（可丢弃缓存）。安装目录不可写时回退到
///     `%LOCALAPPDATA%/MyComic/userdata`（见 [resolveProgramStateRootSync]）。
///
/// Ticket 12 起旧 root getter / alias / 布局锚点全部删除：新 root API 是唯一的
/// 路径解析入口。
///
/// fresh-start 语义：旧版 Fushi / my-comic 的 `<Documents>/Fushi/data`、
/// `%APPDATA%` 数据、`data_root` / `documents_layout` / `documents_container`
/// 都不参与根解析，也不会被迁移（见 storage-layout spec）。
///
/// [AppPaths.resolve] 在启动期解析一次并创建所有根目录；静态便捷层给无法持有
/// `AppModel` 的静态存储助手使用，与实例 API 共用同一份解析函数。
class DataRootUnavailableException implements Exception {
  DataRootUnavailableException({required this.configuredPath});

  /// 配置的根绝对路径（本次不可达，但数据仍在此处）。
  final String configuredPath;

  @override
  String toString() =>
      'DataRootUnavailableException(configuredPath: $configuredPath)';
}

class AppPaths {
  AppPaths._({
    required this.contentRoot,
    required this.downloadsRoot,
    required this.autobackupRoot,
    required this.localComicRoot,
    required this.programStateRoot,
    required this.stateRoot,
    required this.cacheRoot,
    required this.customFontsRoot,
    required this.webView2Root,
    required this.logsRoot,
    required this.programStateRootIsFallback,
    required this.contentRootIsDefault,
    this.contentRootRebaseFrom,
  });

  /// 用户可见的内容根（默认 `<Documents>/MyComic`，可配置）。
  final Directory contentRoot;

  /// Content root 下的在线下载库根 `<content>/downloads`。
  final Directory downloadsRoot;

  /// Content root 下存放 Backup 的目录 `<content>/autobackup`。
  final Directory autobackupRoot;

  /// Content root 下的本地源根 `<content>/localcomic`。
  final Directory localComicRoot;

  /// 程序状态根（默认 `<exeDir>/userdata`）。
  final Directory programStateRoot;

  /// 程序状态中的持久状态根 `<programState>/state`（DB、prefs、Mihon runtime…）。
  final Directory stateRoot;

  /// 程序状态中的可丢弃缓存根 `<programState>/cache`。
  final Directory cacheRoot;

  /// 程序状态中的自定义字体根 `<programState>/state/custom_fonts`。
  ///
  /// Ticket 02：字体是 Portable state 的一部分，必须随程序目录 + `userdata` 走，
  /// 不再落在 Content root（用户可见的漫画内容根）下。
  final Directory customFontsRoot;

  /// 程序状态中的 WebView2 user data folder `<programState>/state/webview2`。
  final Directory webView2Root;

  /// 程序状态中的日志根 `<programState>/state/logs`。
  final Directory logsRoot;

  /// 程序状态是否使用了安装目录不可写时的回退位置。
  final bool programStateRootIsFallback;

  /// 本次解析是否使用默认 Content root（`<Documents>/MyComic`）。
  final bool contentRootIsDefault;

  /// 本次启动从哪个**旧用户的默认 Content root** 自动 rebase 过来；null = 没发生。
  ///
  /// Ticket 02：程序目录连同 `userdata` 拷到另一个 Windows 用户后，偏好里仍可能记着
  /// `C:\Users\<oldUser>\Documents\MyComic`。启动时自动改用当前用户默认根，并把旧根
  /// 交给启动期路径 rebase（[contentRootIsDefault] 仍为 true）。
  final String? contentRootRebaseFrom;

  // ---- 根目录名与偏好键 ----

  /// Content root 的默认目录名（`<Documents>/MyComic`）。
  static const String contentRootDirName = 'MyComic';

  /// Program state root 的目录名（exe 同级的 `userdata`）。
  static const String programStateRootDirName = 'userdata';

  /// Program state root 下的持久状态子目录名。
  static const String stateDirName = 'state';

  /// Program state root 下的可丢弃缓存子目录名。
  static const String cacheDirName = 'cache';

  /// Program state root 下 `state/` 内的自定义字体子目录名。
  static const String customFontsDirName = 'custom_fonts';

  /// Program state root 下 `state/` 内的 WebView2 user data folder 子目录名。
  static const String webView2DirName = 'webview2';

  /// Program state root 下 `state/` 内的日志子目录名。
  static const String logsDirName = 'logs';

  /// Content root 下在线下载库的子目录名。
  static const String downloadsDirName = 'downloads';

  /// Content root 下 Backup 目录的子目录名。
  static const String autobackupDirName = 'autobackup';

  /// Content root 下本地源根的子目录名。
  static const String localComicDirName = 'localcomic';

  /// 用户选择的 Content root 绝对路径（SharedPreferences，落 Program state root 的
  /// `state/shared_preferences.json`）。DB 打开前即可读，供 [resolve] 解析。
  /// 尚未设置时使用默认 `<Documents>/MyComic`。
  static const String contentRootPrefKey = 'content_root';

  /// 仅供测试：覆盖 [fushiTestDirectory] 读取的环境（使单元测试能注入临时测试根）。
  @visibleForTesting
  static Map<String, String>? debugTestEnvironment;

  /// 仅供测试：覆盖「exe 路径」，让程序状态根解析可在临时目录里断言。
  @visibleForTesting
  static String? debugExecutablePathOverride;

  /// 仅供测试：覆盖 `%LOCALAPPDATA%` 回退根。
  @visibleForTesting
  static String? debugLocalAppDataOverride;

  static Directory? _testDirectory(String child) =>
      fushiTestDirectory(child, environment: debugTestEnvironment);

  /// flutter test 宿主没有真实安装目录（exe 在 SDK cache 里）。默认不往那里写
  /// `userdata`；测试要么用 [debugTestEnvironment]，要么显式注入 exe 路径。
  static bool get _isFlutterTestHost =>
      Platform.environment['FLUTTER_TEST'] == 'true';

  /// 解析并创建两个根及其子目录。启动期 `AppModel._prepareRuntimeDirectories`
  /// 调用一次。
  ///
  /// 配置的 Content root 不可达时抛 [DataRootUnavailableException]（除非用户显式
  /// 选择本次用默认位置启动 [forceDefaultRootForSession]），绝不静默建空库。
  static Future<AppPaths> resolve() async {
    final Directory currentDefault = await _defaultContentRoot();
    final Directory content;
    String? configured = forceDefaultRootForSession
        ? null
        : await _configuredContentRootPath();
    String? contentRootRebaseFrom;
    // Ticket 02：便携拷贝到另一个 Windows 用户后，偏好里可能还记着**旧用户**的
    // 默认 `Documents\MyComic`。它不是用户挑的自定义根，而是默认根的绝对化记录；
    // 自动改用当前用户默认根，并让启动期 rebase 把库里记录的路径一起改过去。
    // 只有默认根形状（`.../Documents/MyComic`）才这么做；自定义根缺失仍走逃生屏。
    if (configured != null &&
        isForeignDefaultContentRootPath(
          candidatePath: configured,
          currentDefaultPath: currentDefault.path,
        )) {
      contentRootRebaseFrom = configured;
      configured = null;
      await _clearConfiguredContentRootPreference();
    }

    // Program state root 不依赖 Content root，先解析出来——启动期 Content root
    // 校验需要它判断「不得位于 Program state root 内」。
    final ({Directory root, bool usedFallback}) programState =
        await _resolveProgramStateRoot();

    if (configured != null) {
      final Directory configuredDir = Directory(configured);
      // 先判可达：配置的根掉线/不存在时走「数据位置未响应」逃生屏，绝不在
      // 校验阶段把它新建出来，更不能静默退回默认根建空库。
      if (!await _probeDataRootExists(configuredDir)) {
        throw DataRootUnavailableException(configuredPath: configured);
      }
      // 启动期与切换共用同一套校验（绝对、可写、不碰安装目录与 Program state
      // root）。只校验切换会把「拷来的/手改的 content_root」带进一个不该用的
      // 位置；这里拒绝后交给同一个逃生屏，让用户显式选择默认位置或修正偏好。
      final ContentRootValidationFailure? invalid =
          await ContentRootTargetValidator(
            programStateRoot: programState.root,
            executablePath:
                debugExecutablePathOverride ?? Platform.resolvedExecutable,
          ).validate(configured);
      if (invalid != null) {
        throw DataRootUnavailableException(configuredPath: configured);
      }
      content = configuredDir;
    } else {
      content = currentDefault;
    }

    final Directory state = Directory(
      p.join(programState.root.path, stateDirName),
    );
    final Directory cache = Directory(
      p.join(programState.root.path, cacheDirName),
    );

    final AppPaths paths = AppPaths._(
      contentRoot: content,
      downloadsRoot: Directory(p.join(content.path, downloadsDirName)),
      autobackupRoot: Directory(p.join(content.path, autobackupDirName)),
      localComicRoot: Directory(p.join(content.path, localComicDirName)),
      programStateRoot: programState.root,
      stateRoot: state,
      cacheRoot: cache,
      customFontsRoot: Directory(p.join(state.path, customFontsDirName)),
      webView2Root: Directory(p.join(state.path, webView2DirName)),
      logsRoot: Directory(p.join(state.path, logsDirName)),
      programStateRootIsFallback: programState.usedFallback,
      contentRootIsDefault: configured == null,
      contentRootRebaseFrom: contentRootRebaseFrom,
    );
    await paths._ensureRootsExist();
    return paths;
  }

  /// [candidatePath] 是否形如**另一个 Windows 用户**的默认 Content root
  /// （`...\Documents\MyComic`），且不是当前默认根。
  ///
  /// 用途见 [resolve]：只有这种「默认根被绝对化后跟着 userdata 走」的情况才自动
  /// rebase；用户自己挑的自定义根（即便也叫 MyComic）不可达时必须逃生屏。
  static bool isForeignDefaultContentRootPath({
    required String candidatePath,
    required String currentDefaultPath,
  }) {
    if (!p.isAbsolute(candidatePath)) return false;
    final String candidate = p.normalize(candidatePath);
    final String current = p.normalize(currentDefaultPath);
    if (candidate.toLowerCase() == current.toLowerCase()) return false;
    final List<String> segments = p.split(candidate);
    if (segments.length < 2) return false;
    return segments.last.toLowerCase() == contentRootDirName.toLowerCase() &&
        segments[segments.length - 2].toLowerCase() == 'documents';
  }

  /// 创建 Content root 的四个目录与 Program state root 的 state/cache 及其
  /// Portable state 子目录（custom_fonts / webview2 / logs）。
  ///
  /// 建不出来 = 该位置真的不可用（无权限 / 只读介质 / 盘断链），抛
  /// [DataRootUnavailableException]，由 UI 走「数据位置未响应」逃生屏。
  Future<void> _ensureRootsExist() async {
    for (final Directory dir in <Directory>[
      contentRoot,
      downloadsRoot,
      autobackupRoot,
      localComicRoot,
      programStateRoot,
      stateRoot,
      cacheRoot,
      customFontsRoot,
      webView2Root,
      logsRoot,
    ]) {
      try {
        if (await dir.exists()) continue;
        await dir.create(recursive: true);
      } on FileSystemException {
        throw DataRootUnavailableException(configuredPath: dir.path);
      }
    }
  }

  /// 解析 Content root：配置值优先；否则默认 `<Documents>/MyComic`。
  ///
  /// 静态便捷层不得做文件系统探测（widget 测试的 FakeAsync 相位里真实 IO 的
  /// future 不会完成）——探测只发生在 [resolve]。
  static Future<Directory> _resolveContentRoot() async {
    if (!forceDefaultRootForSession) {
      final String? configured = await _configuredContentRootPath();
      if (configured != null) return Directory(configured);
    }
    return _defaultContentRoot();
  }

  static Future<Directory> _defaultContentRoot() async {
    final Directory? test = _testDirectory('content');
    if (test != null) return test;
    final Directory platformDocuments =
        await getApplicationDocumentsDirectory();
    return Directory(p.join(platformDocuments.path, contentRootDirName));
  }

  /// 读取 `content_root` 偏好（绝对路径）。非桌面 / 未设置 / 非法 / prefs 通道
  /// 不可用 → null（回退默认根）。
  static Future<String?> _configuredContentRootPath() async {
    if (!isDesktopPlatform) return null;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(contentRootPrefKey);
      if (raw == null || raw.trim().isEmpty) return null;
      final String trimmed = raw.trim();
      if (!p.isAbsolute(trimmed)) return null;
      return trimmed;
    } catch (_) {
      // 无插件注册的纯 Dart 测试 / 极端启动早期：按「未设置」处理。
      return null;
    }
  }

  /// Ticket 02：自动 rebase 旧用户默认根后，清掉那条绝对化记录，避免每次启动都
  /// 再忽略一遍；下次便携拷贝由当前默认根重新绝对化。best-effort。
  static Future<void> _clearConfiguredContentRootPreference() async {
    if (!isDesktopPlatform) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(contentRootPrefKey);
    } catch (_) {
      // prefs 通道不可用（纯 Dart 测试）：本次解析已经忽略该偏好，无副作用。
    }
  }

  /// 解析 Program state root。测试根优先；桌面走 `<exeDir>/userdata`，不可写时
  /// 回退 `%LOCALAPPDATA%/MyComic/userdata`；移动端用 app 私有 support 目录。
  static Future<({Directory root, bool usedFallback})>
  _resolveProgramStateRoot() async {
    final Directory? test = _testDirectory(programStateRootDirName);
    if (test != null) return (root: test, usedFallback: false);

    if (isDesktopPlatform) {
      final String? exeOverride = debugExecutablePathOverride;
      if (exeOverride != null || !_isFlutterTestHost) {
        return resolveProgramStateRootSync(
          executablePath: exeOverride ?? Platform.resolvedExecutable,
          localAppDataRoot:
              debugLocalAppDataOverride ?? _defaultLocalAppDataRoot(),
        );
      }
    }
    // 移动端沙盒 / 无注入的 flutter test 宿主：support 目录本身就是 app 私有。
    return (root: await getApplicationSupportDirectory(), usedFallback: false);
  }

  /// 纯桌面同步解析：`<exeDir>/userdata`；不可写时回退
  /// `<localAppData>/MyComic/userdata`；两者都不可写则抛
  /// [DataRootUnavailableException]。
  ///
  /// 同步是有意的：SharedPreferences 的落点必须在进程内第一次 prefs 读取之前定下，
  /// 而 prefs 正是 `state/shared_preferences.json`。
  static ({Directory root, bool usedFallback}) resolveProgramStateRootSync({
    required String executablePath,
    required String localAppDataRoot,
  }) {
    final Directory? test = _testDirectory(programStateRootDirName);
    if (test != null) return (root: test, usedFallback: false);

    final Directory candidate = defaultProgramStateRootFor(executablePath);
    if (_ensureDirectorySync(candidate)) {
      return (root: candidate, usedFallback: false);
    }
    final Directory fallback = fallbackProgramStateRootFor(localAppDataRoot);
    if (_ensureDirectorySync(fallback)) {
      return (root: fallback, usedFallback: true);
    }
    throw DataRootUnavailableException(configuredPath: candidate.path);
  }

  /// `<exeDir>/userdata`。
  static Directory defaultProgramStateRootFor(String executablePath) =>
      Directory(p.join(p.dirname(executablePath), programStateRootDirName));

  /// `%LOCALAPPDATA%/MyComic/userdata`。
  static Directory fallbackProgramStateRootFor(String localAppDataRoot) =>
      Directory(
        p.join(localAppDataRoot, contentRootDirName, programStateRootDirName),
      );

  /// 同步版本，供 `main()` 在第一次 SharedPreferences 读取之前安装 prefs store。
  ///
  /// 返回 null：移动端（平台自己管理 prefs 落点）、无注入的 flutter test 宿主，
  /// 或两个候选都建不出来（此时沿用平台 store，`resolve()` 会给出明确错误）。
  static Directory? programStateRootDirectorySync() {
    final Directory? test = _testDirectory(programStateRootDirName);
    if (test != null) return test;
    if (!isDesktopPlatform) return null;
    if (debugExecutablePathOverride == null && _isFlutterTestHost) return null;
    try {
      return resolveProgramStateRootSync(
        executablePath:
            debugExecutablePathOverride ?? Platform.resolvedExecutable,
        localAppDataRoot:
            debugLocalAppDataOverride ?? _defaultLocalAppDataRoot(),
      ).root;
    } on DataRootUnavailableException {
      return null;
    }
  }

  static String _defaultLocalAppDataRoot() {
    final String? localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.trim().isNotEmpty) {
      return localAppData.trim();
    }
    final String? home =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (home != null && home.trim().isNotEmpty) {
      return p.join(home.trim(), 'AppData', 'Local');
    }
    return Directory.systemTemp.path;
  }

  /// 创建目录并真实写一个探针文件，确认可写。返回 false 表示该候选不可用。
  static bool _ensureDirectorySync(Directory dir) {
    try {
      dir.createSync(recursive: true);
      final File probe = File(p.join(dir.path, '.my_comic_write_probe_$pid'));
      probe.writeAsStringSync('', flush: true);
      probe.deleteSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// TODO-1260 / BUG-572：对目录做**带 2s 超时的异步存在性探测**。Content root
  /// 可能落在网络盘 / 移动盘上，盘掉线时同步 `existsSync()` 会卡住主 isolate。
  /// 只准 `exists().timeout(...)`，永不 `existsSync()`。
  static Future<bool> _probeDataRootExists(Directory dir) async {
    try {
      return await dir.exists().timeout(
        const Duration(seconds: 2),
        onTimeout: () => false,
      );
    } catch (_) {
      return false;
    }
  }

  /// 用户在「数据位置未响应」逃生屏选择「仍用默认位置启动」时置真。置真后本次
  /// 启动忽略配置的 Content root（`content_root`），走默认根。
  static bool forceDefaultRootForSession = false;

  // ---- 静态便捷层（给无 AppModel 实例的 static 存储助手） ----

  /// Content root 目录（不创建）。
  static Future<Directory> contentRootDirectory() => _resolveContentRoot();

  /// 当前用户的默认 Content root（`<Documents>/MyComic`，不创建）。
  ///
  /// Ticket 08：切换 Content root 时，目标等于默认根就清除 `content_root` 偏好，
  /// 让 portable copy 的默认根 rebase 语义保持成立。
  static Future<Directory> defaultContentRootDirectory() =>
      _defaultContentRoot();

  /// `<content>/downloads`（不创建）。
  static Future<Directory> downloadsRootDirectory() async =>
      Directory(p.join((await _resolveContentRoot()).path, downloadsDirName));

  /// `<content>/autobackup`（不创建）。
  static Future<Directory> autobackupRootDirectory() async =>
      Directory(p.join((await _resolveContentRoot()).path, autobackupDirName));

  /// `<content>/localcomic`（不创建）。
  static Future<Directory> localComicRootDirectory() async =>
      Directory(p.join((await _resolveContentRoot()).path, localComicDirName));

  /// Program state root（不创建）。
  static Future<Directory> programStateRootDirectory() async =>
      (await _resolveProgramStateRoot()).root;

  /// `<programState>/state`（不创建）。
  static Future<Directory> stateRootDirectory() async => Directory(
    p.join((await _resolveProgramStateRoot()).root.path, stateDirName),
  );

  /// `<programState>/cache`（不创建）。
  static Future<Directory> cacheRootDirectory() async => Directory(
    p.join((await _resolveProgramStateRoot()).root.path, cacheDirName),
  );

  /// `<programState>/state/custom_fonts`（不创建）。
  static Future<Directory> customFontsRootDirectory() async =>
      Directory(p.join(await _stateRootPath(), customFontsDirName));

  /// `<programState>/state/webview2`（不创建）。
  static Future<Directory> webView2RootDirectory() async =>
      Directory(p.join(await _stateRootPath(), webView2DirName));

  /// `<programState>/state/logs`（不创建）。
  static Future<Directory> logsRootDirectory() async =>
      Directory(p.join(await _stateRootPath(), logsDirName));

  static Future<String> _stateRootPath() async =>
      p.join((await _resolveProgramStateRoot()).root.path, stateDirName);

  /// 同步解析 `state/` 根（不创建）；WebView2 必须在任何 WebView 创建前设置
  /// user data folder，而那时还没有异步入口。测试根 / 桌面 exe 覆盖与
  /// [programStateRootDirectorySync] 同一套规则。
  static Directory? stateRootDirectorySync() {
    final Directory? root = programStateRootDirectorySync();
    if (root == null) return null;
    return Directory(p.join(root.path, stateDirName));
  }
}
