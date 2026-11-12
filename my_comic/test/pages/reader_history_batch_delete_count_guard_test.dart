import 'package:flutter_test/flutter_test.dart';

import 'reader_history_source_corpus.dart';

/// BUG-439 source guard: the shelf batch-delete must count only books whose
/// rows were actually removed, never optimistically `deleted++` and then claim
/// "已删除 N 本"。独立化后书架只剩漫画域，批量删除统一走
/// `removeMangaFromLibrary` 的 `result.removed` 结果。
void main() {
  group('reader history batch delete honesty (BUG-439)', () {
    test('SRT branch only counts genuine deletions, not optimistic success',
        () {
      final String source = readReaderHistorySource();

      final int start = source.indexOf('Future<void> _batchDeleteConfirm(');
      expect(start, isNonNegative,
          reason: '_batchDeleteConfirm must exist in the shelf history page');
      // 2026-10 体验优化：确认后的执行体拆进 `_runBatchDelete`（外层负责忙碌态
      // 进度弹窗），计数门控随之搬家；窗口延伸到执行体结尾，不变量不变。
      final int runner =
          source.indexOf('Future<void> _runBatchDelete(', start + 1);
      expect(runner, isNonNegative,
          reason: 'batch delete runner must follow _batchDeleteConfirm');
      final int end = source.indexOf('Future<void>', runner + 1);
      final String body =
          end > start ? source.substring(start, end) : source.substring(start);

      expect(
        body.contains('removeMangaFromLibrary('),
        isTrue,
        reason: '漫画批量删除必须走统一的移出库入口',
      );
      expect(
        body.contains('await repo.delete(uid'),
        isFalse,
        reason: '非漫画 SRT 分支已删除，不得再按 uid 删行',
      );
      // 不写死门控的字面形状：删除结果的类型会随需求扩展。BUG-439 的不变量是
      // **门控本身**——计数器只能由这次删除的返回值决定。票 02 起在线漫画 /
      // 本地漫画分支用 removeMangaFromLibrary 的成功结果累加 `succeeded`。
      expect(
        RegExp(
          r'if \((?:result\.)?removed(\.\w+)?( > 0)?\) \{?\s*(?:deleted|succeeded)\+\+',
        ).hasMatch(body),
        isTrue,
        reason: 'only real deletions may be counted (BUG-439).',
      );
      // 这一条正向匹配就足以钉住 BUG-439：它的原始形态是**删掉门控**、`repo.delete`
      // 之后无条件 `deleted++`；门控一没，上面的正则就不匹配 → 红。（变异实测过。）
    });
  });
}
