import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic_core/my_comic_core.dart';

/// v83 顺手修的历史缺口守卫（data-layer-stage2-plan.md §7.7）：
/// deleteEpubBook / deleteSrtBookByUid 此前**不清** media_collection_items ——
/// 成员计数虚高、移空自删失效、孤儿键被 sync 原样发布（垃圾传播）。修法与
/// video/game 删除路径对齐：同事务 removeEntryFromAllCollections。
///
/// 变异实测（2026-08-10，临时破坏 lib 后确认转红、已还原，零 lib 残留）：
///  - packages/my_comic_core/lib/src/database/database_content_misc.part.dart 的
///    deleteEpubBook 去掉 removeEntryFromAllCollections 调用 → epub 两用例红
///    （成员残留 / 空合集不自删）；
///  - packages/my_comic_core/lib/src/database/database_library.part.dart 的
///    deleteSrtBookByUid 去掉同调用 → srt 用例红。
void main() {
  late MyComicDatabase db;

  setUp(() {
    db = MyComicDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
      ),
    );
  });
  tearDown(() => db.close());

  Future<String> insertEpub(String key) async {
    await db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: key,
      title: key,
      epubPath: '/$key.epub',
      extractDir: '/$key',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: 1000,
    ));
    return (await db.resolveEpubBookUid(key))!;
  }

  test('deleteEpubBook 清全部合集成员行（uid 键），混合合集不连坐', () async {
    final String uid = await insertEpub('B1');
    final int c1 = await db.createMediaCollection('混合集');
    await db.addToCollection(c1, MediaKind.epub, uid);
    await db.addToCollection(c1, MediaKind.video, 'v1');
    final int c2 = await db.createMediaCollection('另一集');
    await db.addToCollection(c2, MediaKind.epub, uid);
    await db.addToCollection(c2, MediaKind.srt, 's1');

    await db.deleteEpubBook('B1');

    for (final int cid in <int>[c1, c2]) {
      final List<MediaCollectionItemRow> rest =
          await db.getCollectionItems(cid);
      expect(
        rest.map((MediaCollectionItemRow m) => m.entryKey).toList(),
        isNot(contains(uid)),
        reason: '删书必须同事务清其全部合集成员行（否则孤儿 uid 被 sync 原样发布）',
      );
      expect(rest, hasLength(1), reason: '其它成员不连坐');
    }
  });

  test('deleteEpubBook 清成员后移空的合集自删（移空自删语义不失效）', () async {
    final String uid = await insertEpub('B2');
    final int cid = await db.createMediaCollection('独苗集');
    await db.addToCollection(cid, MediaKind.epub, uid);

    await db.deleteEpubBook('B2');

    expect(await db.getMediaCollectionById(cid), isNull,
        reason: '唯一成员被删书清掉后，合集应随移空自删（不留 0 成员孤儿卡）');
  });

}
