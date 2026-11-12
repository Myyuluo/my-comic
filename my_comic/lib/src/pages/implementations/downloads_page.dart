import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_comic/src/media/downloads/download_task_entry.dart';
import 'package:my_comic/src/media/downloads/manga_download_tasks_section.dart';
import 'package:my_comic/src/media/manga/download/manga_download_service.dart';
import 'package:my_comic/src/models/app_model.dart';
import 'package:my_comic/src/utils/components/my_comic_floating_chrome.dart'
    show
        MyComicFloatingChromeBar,
        MyComicFloatingChromeHost,
        MyComicFloatingChromeInsetSpacer;
import 'package:my_comic/src/utils/components/my_comic_staggered_entrance.dart';
import 'package:my_comic/src/utils/components/glass/my_comic_icon.dart';
import 'package:my_comic/src/utils/my_comic_icons.dart';
import 'package:my_comic/utils.dart';
import 'package:material_ui/material_ui.dart';

/// 一级「下载」页（2026-11-07 从浏览页的「下载」视图页签迁出）。
///
/// 标题与浏览页同源：与浏览页共用 [MyComicFloatingChromeHost] 的接线（同一份
/// controller、滚动收放阈值与动画），工具区行只画外壳下发的标题胶囊
/// （[MyComicShellInlineTitle]），不画任何视图页签、也没有额外动作。工具区叠在
/// 列表上，收放不改列表视口。
///
/// 逐设计系统与浏览页一致：MD3 宽窗显示页内标题胶囊；MD3 窄窗不显示页面标题
/// （标题在底部导航里）；Apple / 玻璃设计不画页内工具区，标题交给外壳大标题
/// 随滚动收起。
///
/// 列表在浮动工具区内部用 [MyComicFloatingChromeInsetSpacer] 读取运行时实测的
/// 顶边留白：首张任务卡片从标题下方开始，标题收起后内容继续上移，不留空白条。
/// 旧下载视图的遮挡根因是列表从工具区外层 context 读留白、漏算标题栏高度；这里
/// 不再复现那种读法。也刻意不启用富任务浏览器（摘要 / 筛选 / 搜索 / 批量工具）。
///
/// 动效按仓库规则（MyComic-CLAUDE「新模块 / 重设计页面必须带动效」）：任务卡片在
/// [MyComicEntranceScope] 的进场窗口内错峰淡入上移；滚动带出来的项由窗口关闭后的
/// [MyComicStaggeredEntrance] 直接显示，不拖影。
class DownloadsPage extends ConsumerStatefulWidget {
  const DownloadsPage({super.key, this.downloadsOverride});

  /// 测试注入下载服务（null = 取 [AppModel.mangaDownloadService]）。
  final MangaDownloadService? downloadsOverride;

  @override
  ConsumerState<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends ConsumerState<DownloadsPage> {
  MangaDownloadService? _downloads;

  /// 当前可见任务（由 [MangaDownloadTasksSection] 每次重载后回调），全局按钮
  /// 的文案只由它决定：空 → 隐藏；全是暂停 / 失败 → 全部继续；否则全部暂停。
  List<DownloadTaskEntry> _entries = const <DownloadTaskEntry>[];

  @override
  void initState() {
    super.initState();
    final MangaDownloadService? injected = widget.downloadsOverride;
    if (injected != null) {
      _downloads = injected;
      return;
    }
    final AppModel appModel = ref.read(appProvider);
    _downloads = appModel.isDatabaseReady
        ? appModel.mangaDownloadService
        : null;
  }

  /// 列表非空且所有任务都是暂停或失败 → 全局按钮显示「全部继续」。
  bool get _canResumeAll =>
      _entries.isNotEmpty &&
      _entries.every(
        (DownloadTaskEntry entry) =>
            entry.status == DownloadTaskStatus.paused ||
            entry.status == DownloadTaskStatus.attention,
      );

  void _onTasksChanged(List<DownloadTaskEntry> entries) {
    if (!mounted) return;
    setState(() => _entries = entries);
  }

  Future<void> _toggleAll(bool resume) async {
    final MangaDownloadService? downloads = _downloads;
    if (downloads == null) return;
    if (resume) {
      await downloads.resumeAll();
    } else {
      await downloads.pauseAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    final MyComicDesignTokens tokens = MyComicDesignTokens.of(context);
    final double bottomInset = MediaQuery.paddingOf(context).bottom;
    final double fabExtent = myComicFabMetrics(MyComicFabSize.regular).extent;
    final bool showGlobalButton = _downloads != null && _entries.isNotEmpty;
    final bool resumeAll = _canResumeAll;
    // 用户口径：右下角按钮文字 15；图标字形与文字视觉同高。图标有字形内边距，
    // 15 的盒只有约 8–9px 可见高度，所以盒取 24（字形可见高度约 15），
    // 保持图标自身比例。粗体字形与 onSecondaryContainer 前景不变。
    final TextStyle pillLabelStyle = MyComicPageChromeTitle.titleStyleOf(
      context,
    ).copyWith(
      fontSize: 15,
      color: Theme.of(context).colorScheme.onSecondaryContainer,
    );
    return MyComicFloatingChromeHost(
      // 玻璃设计系统与浏览页一致：页内工具区不画，标题由外壳大标题承担
      // （滚动收起）。MD3 下工具区行只画标题胶囊；窄窗 / 没有外壳标题作用域
      // 时 [MyComicShellInlineTitle] 关闭，行里不会出现页面标题。
      chromeBuilder: (BuildContext context, _, MyComicShellActionsSlot slot) =>
          isGlassDesign(context)
          ? const SizedBox.shrink()
          : MyComicFloatingChromeBar(tabs: const SizedBox.shrink(), slot: slot),
      child: MyComicEntranceScope(
        child: Stack(
          children: <Widget>[
            ListView(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.page,
                tokens.spacing.page,
                tokens.spacing.page,
                // 给右下角全局按钮留位：最后一张任务卡滚到底也不能被盖住。
                bottomInset +
                    tokens.spacing.page +
                    fabExtent +
                    tokens.spacing.gap,
              ),
              children: <Widget>[
                // 在浮动工具区内部读实测 inset（不写死高度、不从工具区外层的
                // context 读）：首卡从标题下方开始，标题收起后内容继续上移。
                const MyComicFloatingChromeInsetSpacer(),
                MangaDownloadTasksSection(
                  downloadsOverride: widget.downloadsOverride,
                  onTasksChanged: _onTasksChanged,
                  tasksBuilder:
                      (BuildContext context, List<DownloadTaskEntry> entries) {
                        if (entries.isEmpty) {
                          // 空态下压一段呼吸位，避免插画紧贴浮动标题。
                          return MyComicStaggeredEntrance(
                            index: 0,
                            child: Padding(
                              padding: EdgeInsets.only(
                                top: tokens.spacing.page * 2,
                              ),
                              child: MyComicPlaceholderMessage(
                                icon: MyComicIcons.download,
                                message: t.downloads_page_no_tasks,
                              ),
                            ),
                          );
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            for (int i = 0; i < entries.length; i++)
                              MyComicStaggeredEntrance(
                                index: i,
                                child: entries[i].builder(context),
                              ),
                          ],
                        );
                      },
                ),
              ],
            ),
            // 全局暂停 / 继续只此一颗（ticket 07）：列表空时隐藏；所有任务都是
            // 暂停 / 失败时显示「全部继续」，否则显示「全部暂停」。行内不提供
            // 暂停 / 继续。
            if (showGlobalButton)
              PositionedDirectional(
                end: tokens.spacing.page,
                bottom: bottomInset + tokens.spacing.page,
                child: MyComicFloatingTextAction(
                  child: MyComicTooltip(
                    message: resumeAll
                        ? t.download_resume_all
                        : t.download_pause_all,
                    child: FilledButton.icon(
                      key: const ValueKey<String>(
                        'downloads-global-toggle-fab',
                      ),
                      onPressed: () => unawaited(_toggleAll(resumeAll)),
                      icon: MyComicIcon(
                        resumeAll ? MyComicIcons.play : MyComicIcons.pause,
                        size: 24,
                      ),
                      label: Text(
                        resumeAll
                            ? t.download_resume_all
                            : t.download_pause_all,
                        style: pillLabelStyle,
                      ),
                      style: FilledButton.styleFrom(
                        textStyle: pillLabelStyle,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
