/// 库页「重置阅读状态 / 清除观看进度」的落地层（用户 2026-10-05：「不小心点到书」
/// 之后要能把它变回没读过的样子）。
///
/// 两件事分开、各走既有的同步安全原语，**不裸删任何会被对端回灌的行**：
///
/// * **位置**（书 / 漫画）：不删 `reader_positions` 行，而是写一条「回到开头」的
///   新位置（section 0、分数 0、精确锚 -1）并把 `updatedAt` 抬到严格新于旧行。
///   删行在两条同步通道上都会被对端原样灌回：互联三方判定把「本端无记录」判成
///   `applyRemote`（`resolveBookProgressThreeWay`），云通道把本端 null 时间戳判成
///   从云导入；写一条新位置则是「本端动过」，两边都按推送处理，对端随之归零。
///   页式阅读器（漫画）落位置恒传 `charOffset >= 0`，所以「section 0 + 精确锚
///   缺席」这一形状只会来自本函数，书架据此把它判成未读（见
///   `ReaderFushiSource._bookToMediaItem` 的页式分支）。
/// * **读完标记**：`EpubBooks.completedAt` 置空（与「取消已读完」同一原语）。
///
/// 收藏、制卡历史、书签、高亮一律不动。阅读统计的清除入口随统计域一起移除
/// （ticket 05）。
library;

import 'package:drift/drift.dart' show Value;
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// 把书（漫画，或配对了 EPUB 的有声书）重置为未读。
///
/// [bookKey] 是书架身份；[nowMs] 仅供测试注入。
Future<void> resetBookReadingState({
  required FushiDatabase db,
  required String bookKey,
  int? nowMs,
}) async {
  if (bookKey.isEmpty) return;
  final EpubBookRow? book = await db.getEpubBook(bookKey);
  final String uid = book?.uid ?? '';
  if (uid.isNotEmpty) {
    final ReaderPositionRow? existing = await db.getReaderPosition(uid);
    // 从没留过位置 = 本来就是未读，不凭空造一行（否则它会顶进「最近阅读」排序）。
    if (existing != null) {
      final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
      // 严格新于旧行：云通道按时间戳三方判定，同毫秒会被判成「没变」。
      final int ts = now > existing.updatedAt ? now : existing.updatedAt + 1;
      await db.upsertReaderPosition(
        ReaderPositionsCompanion(
          bookUid: Value<String>(uid),
          sectionIndex: const Value<int>(0),
          normCharOffset: const Value<int>(0),
          charOffset: const Value<int>(-1),
          updatedAt: Value<int>(ts),
        ),
      );
    }
  }
  await db.setEpubBookCompleted(bookKey, null);
  // 带有声书时首次按播放正文会跟到音频位置（BUG-3430），只回写阅读位置会被音频位置
  // 原样拉回去、再被阅读器落库成「在读」；音频位置一并归零（带时间戳，互联 LWW 随之推送）。
  //
  // my-comic 的漫画-only live schema（37 表）没有 audiobooks 这张非漫画表：
  // 表不存在 = 本书没有有声书记录，跳过位置归零；完整 schema 行为不变。
  // 单卡菜单与批量栏共用本函数，守卫放在这里两处入口同时生效。
  if (await db.hasAudiobooksTable) {
    final AudiobookRepository audiobooks = AudiobookRepository(db);
    if (await audiobooks.findByBookKey(bookKey) != null) {
      await audiobooks.updatePositionMs(bookKey: bookKey, positionMs: 0);
    }
  }
}
