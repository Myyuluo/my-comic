import 'package:material_ui/material_ui.dart';

import 'package:my_comic/src/utils/components/deletion_disclosure.dart';
import 'package:my_comic/utils.dart';

/// 用户在漫画「移出书架」弹窗里做出的可选动作。
///
/// 默认不勾选；弹窗不记忆上次选择（旧 `delete_prompt_remembered_choices`
/// 偏好已不再读取）。取消返回 null。
class MangaLibraryRemovalDecision {
  const MangaLibraryRemovalDecision({required this.deleteLocalFiles});

  /// 在线 Manga 删除 Download library 里的已下载章节；本地 Manga 删除 Local
  /// source root 里的原作文件夹/文件。
  final bool deleteLocalFiles;
}

/// 漫画「移出书架」的统一确认弹窗：标题、说明、一个默认不勾选的选项与
/// 取消/删除按钮。在线与本地 Manga 作品页共用；书架批量/单卡与 Local source
/// 批量入口也应复用本函数，保持文案与结构一致。
///
/// 刻意不使用 [DeletionDisclosure] 的粉/蓝披露块、不提供「记住这些选择」、也不
/// 显示同步能力说明——这是本功能明确要移除的三块内容。删除范围由标题下的说明
/// 与选项的副标题直接讲清。
///
/// 统计删除（ticket 05）已移除：移出书架不再提供「同时删除统计数据」。
Future<MangaLibraryRemovalDecision?> showMangaShelfRemovalDialog(
  BuildContext context, {
  required String message,
  required String localFilesSubtitle,
}) => showAppDialog<MangaLibraryRemovalDecision>(
  context: context,
  builder: (_) => _MangaShelfRemovalDialog(
    message: message,
    localFilesSubtitle: localFilesSubtitle,
  ),
);

class _MangaShelfRemovalDialog extends StatefulWidget {
  const _MangaShelfRemovalDialog({
    required this.message,
    required this.localFilesSubtitle,
  });

  final String message;
  final String localFilesSubtitle;

  @override
  State<_MangaShelfRemovalDialog> createState() =>
      _MangaShelfRemovalDialogState();
}

class _MangaShelfRemovalDialogState extends State<_MangaShelfRemovalDialog> {
  bool _deleteLocalFiles = false;
  bool _saving = false;

  void _confirm() {
    if (_saving) return;
    setState(() => _saving = true);
    Navigator.pop(
      context,
      MangaLibraryRemovalDecision(deleteLocalFiles: _deleteLocalFiles),
    );
  }

  @override
  Widget build(BuildContext context) {
    final MyComicDesignTokens tokens = MyComicDesignTokens.of(context);
    return MyComicDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      child: MyComicModalSheetFrame(
        title: t.manga_series_remove_from_bookshelf,
        leadingIcon: Icons.delete_outline,
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
            Text(widget.message, style: tokens.type.listSubtitle),
            SizedBox(height: tokens.spacing.gap),
            DeleteLocalFilesRow(
              key: const ValueKey<String>(
                'manga_remove_dialog_delete_local_files',
              ),
              value: _deleteLocalFiles,
              subtitle: widget.localFilesSubtitle,
              onChanged: (bool value) =>
                  setState(() => _deleteLocalFiles = value),
            ),
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context, null),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDestructiveAction: true,
              onPressed: _saving ? null : _confirm,
              child: Text(t.dialog_delete),
            ),
          ],
        ),
      ),
    );
  }
}

