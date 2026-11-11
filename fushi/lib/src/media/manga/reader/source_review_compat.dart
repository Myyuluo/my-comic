/// 漫画阅读器里「从外部卡片来源打开」的兼容类型。
///
/// Ticket 04 删除了 Anki 制卡与 source-review 会话；阅读器构造函数与条目恢复
/// 分支仍保留这些字段（旧深链不再产生它们）。这里给出最小、无行为的类型，
/// 让阅读器在删除 Anki 装配后仍能编译，同时 SourceReviewScope 恒返回 null。
library;

import 'package:flutter/widgets.dart';

/// 旧卡片来源深链的目标（章节 id / 页码）。my-comic 不再生成。
class CardSourceLink {
  const CardSourceLink({this.chapterId, this.pageIndex});

  final String? chapterId;
  final int? pageIndex;
}

/// 旧的 source-review 会话：my-comic 不再创建，故恒为非 review 状态。
class SourceReviewSession extends ChangeNotifier {
  bool get isReview => false;
}

/// 旧的 source-review 作用域：恒无会话。
abstract final class SourceReviewScope {
  static SourceReviewSession? maybeOf(BuildContext context) => null;
}
