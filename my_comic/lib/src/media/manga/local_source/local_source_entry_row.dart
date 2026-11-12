import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_comic/src/media/online/installed_online_source_row.dart';
import 'package:my_comic/src/models/app_model.dart';
import 'package:my_comic/src/utils/components/my_comic_staggered_entrance.dart';
import 'package:my_comic/utils.dart';

/// 「本地图源」是否参与图源列表。偏好未就绪时按默认值 true 处理（与仓库默认
/// 一致）——这条路径只在 widget 测试 / 极早期启动出现。
bool isLocalSourceEnabled(AppModel appModel) =>
    !appModel.isPreferencesReady || appModel.localSourceEnabled;

/// 内置「本地图源」在图源列表里的一行。
///
/// 照旧 Mokuro.moe 的内置伪源做法（用户口径）：不是 `manga_online_sources` 行、
/// 不由 Extension 提供、不走扩展启用 / 安装检查；固定排在所有扩展源与「已置顶」
/// 分组之上，没有置顶 / 排序 / 清除数据 / 卸载扩展菜单。行内容 = 开关 + 名称 +
/// `local` 的绝对路径（过长由 [InstalledOnlineSourceRow] 统一截断），没有
/// 语言 tag。
///
/// 开关语义与普通源行一致：关掉后行保留、置灰、不可进入。
class LocalSourceEntryRow extends ConsumerWidget {
  const LocalSourceEntryRow({super.key, this.onOpen});

  /// 点行进本地图源页面；为 null 时行不可点。关闭状态下一律不可点。
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppModel appModel = ref.watch(appProvider);
    final bool ready = appModel.isPreferencesReady;
    final bool enabled = isLocalSourceEnabled(appModel);
    // 绝对路径：`<Content root>/local`。路径尚未解析时先不给副标题，
    // 解析完成后 AppModel 会触发重建（设置页同款降级）。
    final String? localRootPath = appModel.appPathsOrNull?.localComicRoot.path;
    return MyComicStaggeredEntrance(
      index: 0,
      child: InstalledOnlineSourceRow(
        index: 0,
        count: 1,
        rowKey: const ValueKey<String>('local_source_row'),
        title: t.local_source_title,
        enabled: enabled,
        onEnabledChanged: ready
            ? (bool value) =>
                  unawaited(appModel.setLocalSourceEnabled(value))
            : null,
        detail: localRootPath,
        onOpen: onOpen,
      ),
    );
  }
}
