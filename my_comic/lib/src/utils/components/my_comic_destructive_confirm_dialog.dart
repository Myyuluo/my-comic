import 'package:material_ui/material_ui.dart';
import 'package:my_comic/i18n/strings.g.dart';
import 'package:my_comic/src/utils/components/deletion_disclosure.dart';
import 'package:my_comic/src/utils/adaptive/adaptive_widgets.dart';
import 'package:my_comic/src/utils/components/my_comic_design_tokens.dart';
import 'package:my_comic/src/utils/components/my_comic_material_components.dart';
import 'package:my_comic/src/utils/components/glass/my_comic_glass_controls.dart';

/// [MyComicDestructiveConfirmDialog] 的返回值。
///
/// pop `null` = 取消；非 null = 已确认，[checked] 携带可选勾选项状态
/// （无 [MyComicDestructiveConfirmDialog.checkboxLabel] 时恒为 false）。
/// [deleteLocalFiles] 是挂在 [checked] 之下的二级勾选（subtitle 没传、或主勾选
/// 未勾时恒为 false）。
@immutable
class MyComicDestructiveConfirmResult {
  const MyComicDestructiveConfirmResult({
    required this.checked,
    this.deleteLocalFiles = false,
    this.deleteSubscriptions = false,
  });

  final bool checked;

  /// 用户是否要求连磁盘上的原始文件一起删（仅在 [checked] 为真时可能为真）。
  final bool deleteLocalFiles;

  /// 用户是否要求连归属的下载订阅一起删（没传
  /// [MyComicDestructiveConfirmDialog.deleteSubscriptionsLabel] 时恒为 false）。
  final bool deleteSubscriptions;
}

/// 全 app 统一的「确认销毁」对话框。
///
/// 巡检（docs/reviews/2026-07-22-ui-ux-survey.md）发现同一语义至少四种实现
/// 并存：ReaderHistoryDeleteDialog、CollectionDeleteDialog、两个合集详情页的
/// 裸 AlertDialog。本组件以 ReaderHistoryDeleteDialog 的观感为基准
/// （MyComicDialogFrame + MyComicModalSheetFrame + adaptiveDialogAction），
/// 增加可选勾选项（如「连同书籍本体一起删除」），供各处收口。
///
/// 用法：`showAppDialog<MyComicDestructiveConfirmResult>(...)` 后判空即可；
/// 确认按钮文案默认 t.dialog_delete，可换（如「清空」「移除」）。
class MyComicDestructiveConfirmDialog extends StatefulWidget {
  const MyComicDestructiveConfirmDialog({
    required this.title,
    required this.message,
    this.confirmLabel,
    this.leadingIcon = Icons.delete_outline,
    this.checkboxLabel,
    this.checkboxInitialValue = false,
    this.localFilesSubtitle,
    this.checkedDisclosure,
    this.checkedNote,
    this.deleteSubscriptionsLabel,
    this.checkboxKey,
    this.confirmKey,
    this.requireCheckboxToConfirm = false,
    super.key,
  }) : assert(
         !requireCheckboxToConfirm || checkboxLabel != null,
         '防呆闸没有勾选项就是一颗永远点不动的按钮',
       );

  final String title;
  final String message;

  /// 确认按钮文案；null 用 t.dialog_delete。
  final String? confirmLabel;

  final IconData leadingIcon;

  /// 非 null 时在正文下方渲染一个勾选行（如「连同本体删除」）。
  final String? checkboxLabel;

  final bool checkboxInitialValue;

  /// 非 null 时，在主勾选被勾上后追加渲染二级勾选行「同时删除本地文件」
  /// （[DeleteLocalFilesRow]，与单条删除确认框同一行组件、同一文案）。
  ///
  /// 语义分层是这两行的全部理由：主勾选决定「库里的条目删不删」，二级勾选决定
  /// 「磁盘上的原件删不删」。把两件事压进一行文案（旧实现的「同时删除其中的视频
  /// （保留你的原始视频文件）」）等于替用户把后一个决定定死。null = 这个入口没有
  /// 可删的本机原件（书 / 游戏合集），此时结果里的 [
  /// MyComicDestructiveConfirmResult.deleteLocalFiles] 恒 false。
  ///
  /// 二级行只在主勾选为真时可见，主勾选取消时其状态一并复位——隐藏着的 true
  /// 会在用户下次勾主选时静默删掉磁盘原件。
  final String? localFilesSubtitle;

  /// 勾选框被勾上后追加渲染的「会被删除 / 会被保留」逐项披露。
  ///
  /// 根因（BUG-1305）：本对话框的正文 [message] 与勾选行是两个静态节点，勾选翻转
  /// 语义时正文不跟随。合集删除因此出现「删除合集不会删除其中的视频」与「同时删除
  /// 其中的书」同屏并存，而代码按勾选递归删了每本书的解压目录和有声书目录。披露挂
  /// 在勾选状态上，正文才不会再和实际行为说反话。
  final DeletionDisclosure? checkedDisclosure;

  /// 勾选框被勾上后才追加在勾选行下方的一句说明（勾选会多带出的后果，如「对应
  /// 的视频也会从媒体库中移除」）。与 [checkedDisclosure] 同理挂在勾选状态上：
  /// 不勾时这件事不会发生，就不该出现在正文里。
  final String? checkedNote;

  /// 非 null 时在正文下方渲染独立勾选行「同时删除 N 个下载订阅」（删合集用）。
  ///
  /// 与主勾选**正交**：订阅删不删与成员本体删不删无关——只解散合集也该能把
  /// 往这个合集里追更的订阅停掉。默认勾上：合集都不要了，订阅还在后台按身份
  /// 继续下载，是用户最不想要的结果；null = 这个合集没有归属订阅，不摆这一行。
  final String? deleteSubscriptionsLabel;

  /// 勾选行的 key（供测试 / 集成测试焦点驱动定位）。
  final Key? checkboxKey;

  /// 确认（破坏性）按钮的 key（供测试 / 集成测试定位）。
  final Key? confirmKey;

  /// **防呆闸**：true 时确认按钮在勾选前恒禁用（`onPressed: null`）。
  ///
  /// 与默认的「可选项」勾选（如「连同书籍本体一起删除」）是两种语义，别混：
  /// 可选项决定**删多少**，防呆闸决定**能不能删**。用在「按钮就长在常用位置、
  /// 一个纯确认框等同于点两下删光半年数据」的地方（统计页会话区块标题行上的
  /// 「清除全部会话」就是这种）。勾选文案应当把不可逆的范围复述一遍。
  final bool requireCheckboxToConfirm;

  @override
  State<MyComicDestructiveConfirmDialog> createState() =>
      _MyComicDestructiveConfirmDialogState();
}

class _MyComicDestructiveConfirmDialogState
    extends State<MyComicDestructiveConfirmDialog> {
  late bool _checked = widget.checkboxInitialValue;
  bool _deleteLocalFiles = false;
  bool _deleteSubscriptions = true;

  /// 勾选态叠加后的披露：二级勾选把对应条目从「保留」翻到「删除」，
  /// 与 `ReaderHistoryDeleteDialog` 同一叠加顺序（幂等、可交换）。
  DeletionDisclosure _shownDisclosure(DeletionDisclosure base) {
    DeletionDisclosure shown = base;
    if (_deleteLocalFiles) shown = shown.withLocalFilesDeleted();
    return shown;
  }

  @override
  Widget build(BuildContext context) {
    final MyComicDesignTokens tokens = MyComicDesignTokens.of(context);

    return MyComicDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      // 勾选后披露正文会长于矮窗口：仅正文滚动，确认/取消始终留在面板内。
      scrollable: false,
      child: MyComicModalSheetFrame(
        scrollable: true,
        title: widget.title,
        leadingIcon: widget.leadingIcon,
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(widget.message, style: tokens.type.listSubtitle),
            if (widget.checkboxLabel != null) ...[
              SizedBox(height: tokens.spacing.gap),
              MyComicListItem(
                key: widget.checkboxKey,
                density: MyComicListDensity.compact,
                padding: EdgeInsets.zero,
                // BUG-1291：勾选文案是整句解释（「同时删除其中的视频（保留你的
                // 原始视频文件）」），不是列表里的标题短语。[MyComicListItem] 的
                // titleMaxLines 默认 1 + ellipsis，在 420 宽的对话框里会把括号
                // 里的免责说明整段吃掉，用户读到的是「…保留你的原始视…」——恰好
                // 是最需要看清的那半句。此处正文在 [MyComicModalSheetFrame] 内滚动，
                // 高度自由，放开行数不会像
                // BUG-1184 的固定高容器那样撑破布局。
                titleMaxLines: 3,
                title: Text(widget.checkboxLabel!),
                // 勾选状态由整行 onTap 驱动；Checkbox 本身既不接指针也不进
                // 焦点遍历（单站点契约，行即唯一停靠点）。
                leading: ExcludeFocus(
                  child: IgnorePointer(
                    child: MyComicCheckbox(value: _checked, onChanged: (_) {}),
                  ),
                ),
                onTap: () => setState(() {
                  _checked = !_checked;
                  // 主勾选取消 = 连成员都不删，磁盘原件更无从谈起；不复位就会
                  // 留下一个看不见的 true。
                  if (!_checked) {
                    _deleteLocalFiles = false;
                  }
                }),
              ),
              if (_checked && widget.localFilesSubtitle != null)
                DeleteLocalFilesRow(
                  value: _deleteLocalFiles,
                  subtitle: widget.localFilesSubtitle!,
                  onChanged: (bool v) => setState(() => _deleteLocalFiles = v),
                ),
              if (_checked && widget.checkedNote != null)
                Padding(
                  padding: EdgeInsets.only(top: tokens.spacing.gap / 2),
                  child: Text(
                    widget.checkedNote!,
                    key: const ValueKey<String>(
                      'destructive-confirm-checked-note',
                    ),
                    style: tokens.type.listSubtitle,
                  ),
                ),
              if (_checked && widget.checkedDisclosure != null) ...<Widget>[
                SizedBox(height: tokens.spacing.gap),
                DeletionDisclosureView(
                  // 勾了「同时删除本地文件」时披露必须跟着翻面，否则又回到
                  // BUG-1305 那种「正文说保留、代码在删」的说反话状态。
                  disclosure: _shownDisclosure(widget.checkedDisclosure!),
                ),
              ],
            ],
            if (widget.deleteSubscriptionsLabel != null) ...[
              SizedBox(height: tokens.spacing.gap),
              MyComicListItem(
                key: const ValueKey<String>(
                  'destructive-confirm-delete-subscriptions',
                ),
                density: MyComicListDensity.compact,
                padding: EdgeInsets.zero,
                titleMaxLines: 3,
                title: Text(widget.deleteSubscriptionsLabel!),
                leading: ExcludeFocus(
                  child: IgnorePointer(
                    child: MyComicCheckbox(
                      value: _deleteSubscriptions,
                      onChanged: (_) {},
                    ),
                  ),
                ),
                onTap: () => setState(
                  () => _deleteSubscriptions = !_deleteSubscriptions,
                ),
              ),
            ],
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_cancel),
            ),
            KeyedSubtree(
              key: widget.confirmKey,
              child: adaptiveDialogAction(
                context: context,
                isDestructiveAction: true,
                // 防呆闸：未勾选时 onPressed 为 null，按钮真禁用（不是点了没反应）。
                onPressed: widget.requireCheckboxToConfirm && !_checked
                    ? null
                    : () => Navigator.pop(
                        context,
                        MyComicDestructiveConfirmResult(
                          checked: _checked,
                          deleteLocalFiles:
                              _checked &&
                              widget.localFilesSubtitle != null &&
                              _deleteLocalFiles,
                          deleteSubscriptions:
                              widget.deleteSubscriptionsLabel != null &&
                              _deleteSubscriptions,
                        ),
                      ),
                child: Text(widget.confirmLabel ?? t.dialog_delete),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
