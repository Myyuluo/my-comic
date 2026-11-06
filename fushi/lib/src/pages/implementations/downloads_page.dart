import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/media/downloads/manga_download_tasks_section.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show
        FushiFloatingChromeBar,
        FushiFloatingChromeHost,
        FushiFloatingChromeInsetSpacer;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:material_ui/material_ui.dart';

/// 一级「下载」页（2026-11-07 从浏览页的「下载」视图页签迁出）。
///
/// 标题与浏览页同源：与浏览页共用 [FushiFloatingChromeHost] 的接线（同一份
/// controller、滚动收放阈值与动画），工具区行只画外壳下发的标题胶囊
/// （[FushiShellInlineTitle]），不画任何视图页签、也没有额外动作。工具区叠在
/// 列表上，收放不改列表视口。
///
/// 逐设计系统与浏览页一致：MD3 宽窗显示页内标题胶囊；MD3 窄窗不显示页面标题
/// （标题在底部导航里）；Apple / 玻璃设计不画页内工具区，标题交给外壳大标题
/// 随滚动收起。
///
/// 列表在浮动工具区内部用 [FushiFloatingChromeInsetSpacer] 读取运行时实测的
/// 顶边留白：首张任务卡片从标题下方开始，标题收起后内容继续上移，不留空白条。
/// 旧下载视图的遮挡根因是列表从工具区外层 context 读留白、漏算标题栏高度；这里
/// 不再复现那种读法。也刻意不启用富任务浏览器（摘要 / 筛选 / 搜索 / 批量工具）。
///
/// 动效按仓库规则（Fushi-CLAUDE「新模块 / 重设计页面必须带动效」）：任务卡片在
/// [FushiEntranceScope] 的进场窗口内错峰淡入上移；滚动带出来的项由窗口关闭后的
/// [FushiStaggeredEntrance] 直接显示，不拖影。
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key, this.downloadsOverride});

  /// 测试注入下载服务（null = 取 [AppModel.mangaDownloadService]）。
  final MangaDownloadService? downloadsOverride;

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiFloatingChromeHost(
      // 玻璃设计系统与浏览页一致：页内工具区不画，标题由外壳大标题承担
      // （滚动收起）。MD3 下工具区行只画标题胶囊；窄窗 / 没有外壳标题作用域
      // 时 [FushiShellInlineTitle] 关闭，行里不会出现页面标题。
      chromeBuilder: (BuildContext context, _, FushiShellActionsSlot slot) =>
          isGlassDesign(context)
          ? const SizedBox.shrink()
          : FushiFloatingChromeBar(tabs: const SizedBox.shrink(), slot: slot),
      child: FushiEntranceScope(
        child: ListView(
          padding: EdgeInsets.all(tokens.spacing.page),
          children: <Widget>[
            // 在浮动工具区内部读实测 inset（不写死高度、不从工具区外层的
            // context 读）：首卡从标题下方开始，标题收起后内容继续上移。
            const FushiFloatingChromeInsetSpacer(),
            MangaDownloadTasksSection(
              downloadsOverride: widget.downloadsOverride,
              tasksBuilder:
                  (BuildContext context, List<DownloadTaskEntry> entries) {
                    if (entries.isEmpty) {
                      // 空态下压一段呼吸位，避免插画紧贴浮动标题。
                      return FushiStaggeredEntrance(
                        index: 0,
                        child: Padding(
                          padding: EdgeInsets.only(
                            top: tokens.spacing.page * 2,
                          ),
                          child: FushiPlaceholderMessage(
                            icon: FushiIcons.download,
                            message: t.downloads_page_no_tasks,
                          ),
                        ),
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        for (int i = 0; i < entries.length; i++)
                          FushiStaggeredEntrance(
                            index: i,
                            child: entries[i].builder(context),
                          ),
                      ],
                    );
                  },
            ),
          ],
        ),
      ),
    );
  }
}
