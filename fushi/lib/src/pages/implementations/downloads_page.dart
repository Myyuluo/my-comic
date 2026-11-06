import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/media/downloads/manga_download_tasks_section.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:material_ui/material_ui.dart';

/// 一级「下载」页（2026-11-07 从浏览页的「下载」视图页签迁出）。
///
/// 只管布局：顶部是外壳画的固定展开标题（见 `HomePage._shellTitleFor` /
/// `homeTabPinsExpandedTitle`），页内不画标题、不画视图页签。内容就是现有的
/// 简单下载任务列表（`MangaDownloadTasksSection` 的漫画章节任务卡片），没有任务
/// 时显示空态提示。
///
/// 刻意**不**消费 [FushiFloatingChromeInset]：旧下载视图的遮挡根因是列表只读取了
/// 外层浮动工具区留白、没算浏览页标题栏自身高度；迁移后标题在滚动区之外，列表
/// 从标题下方开始，该问题在结构上消失。也刻意不启用富任务浏览器
/// （摘要 / 筛选 / 搜索 / 批量工具）。
///
/// 动效按仓库规则（Fushi-CLAUDE「新模块 / 重设计页面必须带动效」）：任务卡片在
/// [FushiEntranceScope] 的进场窗口内错峰淡入上移；滚动带出来的项由窗口关闭后的
/// [FushiStaggeredEntrance] 直接显示，不拖影。
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key, this.downloadsOverride});

  /// 测试注入下载服务（null = 取 [AppModel.mangaDownloadService]）。
  final MangaDownloadService? downloadsOverride;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiEntranceScope(
      child: ListView(
        padding: EdgeInsets.all(tokens.spacing.page),
        children: <Widget>[
          MangaDownloadTasksSection(
            downloadsOverride: downloadsOverride,
            tasksBuilder:
                (BuildContext context, List<DownloadTaskEntry> entries) {
                  if (entries.isEmpty) {
                    // 空态下压一段呼吸位，避免插画紧贴固定标题。
                    return FushiStaggeredEntrance(
                      index: 0,
                      child: Padding(
                        padding: EdgeInsets.only(top: tokens.spacing.page * 2),
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
    );
  }
}
