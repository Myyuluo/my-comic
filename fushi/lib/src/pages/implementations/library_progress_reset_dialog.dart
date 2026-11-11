import 'package:material_ui/material_ui.dart';

import 'package:fushi/utils.dart';

/// 「重置阅读状态 / 清除观看进度」确认框（书架、漫画库共用，单卡与批量同一份）。
///
/// 正文说清会发生什么（进度归零、改为未读 / 未看、离开「继续」区）。阅读统计
/// 的「同时撤销最近一次学习记录」勾选已随统计域一起移除（ticket 05），确认框
/// 只保留确认 / 取消。
///
/// 结构与删除确认框（`ReaderHistoryDeleteDialog`）一致：[FushiDialogFrame] +
/// [FushiModalSheetFrame] + 破坏性确认动作。
class LibraryProgressResetDialog extends StatelessWidget {
  const LibraryProgressResetDialog({
    required this.title,
    required this.message,
    this.itemTitle,
    super.key,
  });

  /// 对话框标题（书 = 「重置阅读状态」，视频 = 「清除观看进度」）。
  final String title;

  /// 正文说明。
  final String message;

  /// 单项时显示在正文上方的条目名；批量时为 null（正文里已写数量）。
  final String? itemTitle;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String? itemTitle = this.itemTitle;
    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      child: FushiModalSheetFrame(
        title: title,
        leadingIcon: Icons.restart_alt_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (itemTitle != null && itemTitle.trim().isNotEmpty) ...<Widget>[
              Text(
                itemTitle,
                style: tokens.type.listTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: tokens.spacing.gap),
            ],
            Text(message, style: tokens.type.listSubtitle),
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context, false),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(context, true),
              child: Text(t.library_progress_reset_confirm),
            ),
          ],
        ),
      ),
    );
  }
}

/// 弹出 [LibraryProgressResetDialog]；确认返回 true，取消 / 点外面关闭返回 false。
Future<bool> showLibraryProgressResetDialog(
  BuildContext context, {
  required String title,
  required String message,
  String? itemTitle,
}) async {
  final bool? confirmed = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext _) => LibraryProgressResetDialog(
      title: title,
      message: message,
      itemTitle: itemTitle,
    ),
  );
  return confirmed ?? false;
}
