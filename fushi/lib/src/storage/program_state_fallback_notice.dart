import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart'
    show FushiAlertDialog, FushiTextButton, showAppDialog;

/// Ticket 03：安装目录不可写时，Program state root 回退到
/// `%LOCALAPPDATA%\MyComic\userdata`（见 `AppPaths.resolveProgramStateRootSync`）。
/// 回退本身让程序还能启动，但用户的 Library、设置与扩展不再随程序目录走；
/// 必须给一个可见提示，否则「拷走程序目录 = 便携」的预期会静默落空。
///
/// 每**进程**提示一次：切换界面语言会重建整棵 UI 树并重新挂载首页，不能因此再弹；
/// 下次启动仍会提示，直到用户把程序装到可写目录（回退标记在每次启动重新判定）。
enum ProgramStateFallbackNoticeDecision {
  /// 未使用回退位置，或本进程已经提示过。
  none,

  /// 使用回退位置且本进程还没提示过。
  show,
}

/// 纯判定（测试钉住）：[fallbackInUse] 来自
/// `AppPaths.programStateRootIsFallback`，[alreadyShown] 是本进程的提示记录。
ProgramStateFallbackNoticeDecision decideProgramStateFallbackNotice({
  required bool fallbackInUse,
  required bool alreadyShown,
}) {
  if (!fallbackInUse || alreadyShown) {
    return ProgramStateFallbackNoticeDecision.none;
  }
  return ProgramStateFallbackNoticeDecision.show;
}

bool _shownThisProcess = false;

/// 仅供测试：清掉本进程的提示记录。
@visibleForTesting
void debugResetProgramStateFallbackNotice() {
  _shownThisProcess = false;
}

/// 首页首帧调用：使用回退位置时弹一次可见提示。非阻塞失败（context 已卸载）
/// 不标记为已提示，下一次挂载还有机会。
Future<void> maybeShowProgramStateFallbackNotice({
  required BuildContext context,
  required bool fallbackInUse,
  required String fallbackPath,
}) async {
  if (!context.mounted) return;
  final ProgramStateFallbackNoticeDecision decision =
      decideProgramStateFallbackNotice(
        fallbackInUse: fallbackInUse,
        alreadyShown: _shownThisProcess,
      );
  if (decision == ProgramStateFallbackNoticeDecision.none) return;
  _shownThisProcess = true;
  await showProgramStateFallbackNoticeDialog(
    context: context,
    fallbackPath: fallbackPath,
  );
}

/// 提示框本体。复用既有 `FushiAlertDialog`（ADR 0008：只加必要文案，不改设计）。
Future<void> showProgramStateFallbackNoticeDialog({
  required BuildContext context,
  required String fallbackPath,
}) {
  return showAppDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      key: const ValueKey<String>('program_state_fallback_notice'),
      icon: const FushiIcon(Icons.folder_off_outlined),
      title: Text(t.program_state_fallback_notice_title),
      content: Text(
        t.program_state_fallback_notice_message(path: fallbackPath),
      ),
      actions: <Widget>[
        FushiTextButton(
          key: const ValueKey<String>('program_state_fallback_notice_ok'),
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(t.dialog_ok),
        ),
      ],
    ),
  );
}
