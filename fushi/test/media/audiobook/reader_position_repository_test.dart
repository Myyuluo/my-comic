import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_audio/fushi_audio.dart';

void main() {
  late FushiDatabase db;
  late ReaderPositionRepository repo;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = ReaderPositionRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  // TODO-1292（退出图1重进图2）：精确锚绝不能比分数陈旧。同 section 无新精确锚，但
  // norm_char_offset 变了 → 位置真的推进了、旧精确锚陈旧 → 必须失效，恢复回退到最新分数。
  test(
      'same-section null save with moved fraction invalidates stale charOffset',
      () async {
    await repo.save(
      bookUid: 'book-42',
      sectionIndex: 3,
      normCharOffset: 100,
      charOffset: 500,
    );
    var pos = await repo.findByBookUid('book-42');
    expect(pos, isNotNull);
    expect(pos!.charOffset, equals(500));

    await repo.save(
      bookUid: 'book-42',
      sectionIndex: 3,
      normCharOffset: 200,
    );
    pos = await repo.findByBookUid('book-42');
    expect(pos, isNotNull);
    expect(pos!.sectionIndex, equals(3));
    expect(pos.normCharOffset, equals(200),
        reason: 'normCharOffset should update');
    expect(pos.charOffset, isNull,
        reason: 'position moved without a fresh precise anchor → stale '
            'charOffset must be invalidated so restore uses the fresh fraction');
  });

  // BUG-162 瞬态守护保留：同 section、分数不变（当帧测不到精确偏移但位置没动）→ 保留旧锚，
  // 避免一次性 caret 失败就丢掉精确恢复能力。
  test('same-section null save with unchanged fraction preserves charOffset',
      () async {
    await repo.save(
      bookUid: 'book-77',
      sectionIndex: 3,
      normCharOffset: 100,
      charOffset: 500,
    );
    await repo.save(
      bookUid: 'book-77',
      sectionIndex: 3,
      normCharOffset: 100,
    );
    final pos = await repo.findByBookUid('book-77');
    expect(pos, isNotNull);
    expect(pos!.normCharOffset, equals(100));
    expect(pos.charOffset, equals(500),
        reason: 'position unchanged (transient measure failure) → keep anchor');
  });

  test('cross-section null save invalidates local charOffset', () async {
    await repo.save(
      bookUid: 'book-42',
      sectionIndex: 3,
      normCharOffset: 100,
      charOffset: 500,
    );

    await repo.save(
      bookUid: 'book-42',
      sectionIndex: 4,
      normCharOffset: 200,
    );
    final pos = await repo.findByBookUid('book-42');
    expect(pos, isNotNull);
    expect(pos!.sectionIndex, equals(4), reason: 'sectionIndex should update');
    expect(pos.normCharOffset, equals(200),
        reason: 'normCharOffset should update');
    expect(pos.charOffset, isNull,
        reason: 'section-local charOffset must not survive section changes');
  });

  test('save with charOffset then save with new value updates it', () async {
    await repo.save(
      bookUid: 'book-42',
      sectionIndex: 3,
      normCharOffset: 100,
      charOffset: 500,
    );
    await repo.save(
      bookUid: 'book-42',
      sectionIndex: 5,
      normCharOffset: 300,
      charOffset: 800,
    );
    final pos = await repo.findByBookUid('book-42');
    expect(pos!.charOffset, equals(800));
  });

  test('DB default -1 maps to model null for old data', () async {
    await db.into(db.readerPositions).insert(ReaderPositionsCompanion.insert(
          bookUid: 'book-99',
          sectionIndex: 0,
          normCharOffset: 50,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ));
    final pos = await repo.findByBookUid('book-99');
    expect(pos, isNotNull);
    expect(pos!.charOffset, isNull, reason: 'DB -1 should map to model null');
  });

  test('findByTtuBookId returns null for absent book', () async {
    expect(await repo.findByBookUid('book-999'), isNull);
  });

  test('delete removes position', () async {
    await repo.save(
      bookUid: 'book-10',
      sectionIndex: 1,
      normCharOffset: 500,
    );
    await repo.delete('book-10');
    expect(await repo.findByBookUid('book-10'), isNull);
  });

  test('save→restore round-trip preserves all model fields', () async {
    await repo.save(
      bookUid: 'book-7',
      sectionIndex: 5,
      normCharOffset: 3000,
      charOffset: 250,
    );
    final pos = await repo.findByBookUid('book-7');
    expect(pos, isNotNull);
    expect(pos!.bookUid, 'book-7');
    expect(pos.sectionIndex, 5);
    expect(pos.normCharOffset, 3000);
    expect(pos.charOffset, 250);
    expect(pos.updatedAt, greaterThan(0));
    expect(pos.id, isNotNull);
  });

  test('normCharOffset boundary: chapter start (0)', () async {
    await repo.save(bookUid: 'book-1', sectionIndex: 0, normCharOffset: 0);
    final pos = await repo.findByBookUid('book-1');
    expect(pos!.normCharOffset, 0);
  });

  test('normCharOffset boundary: chapter end (10000)', () async {
    await repo.save(bookUid: 'book-2', sectionIndex: 0, normCharOffset: 10000);
    final pos = await repo.findByBookUid('book-2');
    expect(pos!.normCharOffset, 10000);
  });

  test('multiple books have independent positions', () async {
    await repo.save(bookUid: 'book-1', sectionIndex: 3, normCharOffset: 1000);
    await repo.save(bookUid: 'book-2', sectionIndex: 7, normCharOffset: 5000);

    final pos1 = await repo.findByBookUid('book-1');
    final pos2 = await repo.findByBookUid('book-2');
    expect(pos1!.sectionIndex, 3);
    expect(pos2!.sectionIndex, 7);
  });

  test('first save with null charOffset keeps DB default', () async {
    await repo.save(bookUid: 'book-50', sectionIndex: 0, normCharOffset: 100);
    final pos = await repo.findByBookUid('book-50');
    expect(pos!.charOffset, isNull,
        reason: 'first save without charOffset → DB default -1 → model null');
  });

  // 书架列书一次取完（替代每本一查的 N+1）：批量读与单本读逐字段一致。
  test('findAllByBookUid matches per-book reads field by field', () async {
    await repo.save(
        bookUid: 'a', sectionIndex: 3, normCharOffset: 1000, charOffset: 42);
    await repo.save(bookUid: 'b', sectionIndex: 7, normCharOffset: 5000);

    final Map<String, ReaderPosition> all = await repo.findAllByBookUid();

    expect(all.keys.toSet(), <String>{'a', 'b'});
    for (final String uid in all.keys) {
      final ReaderPosition? single = await repo.findByBookUid(uid);
      final ReaderPosition batch = all[uid]!;
      expect(batch.sectionIndex, single!.sectionIndex);
      expect(batch.normCharOffset, single.normCharOffset);
      expect(batch.charOffset, single.charOffset);
      expect(batch.updatedAt, single.updatedAt);
    }
    expect(all['a']!.charOffset, 42);
    expect(all['b']!.charOffset, isNull, reason: 'DB -1 哨兵 → 模型 null');
  });

  test('findAllByBookUid on empty table is empty', () async {
    expect(await repo.findAllByBookUid(), isEmpty);
  });

  // 无痕阅读（ticket 04）：续读位置照常写，但 reader_positions.updatedAt 是
  // History 的可见信号（书架「最近阅读」排序 / 继续阅读 hero / 互联 LWW），
  // 必须冻结。已有行保留原值；新行用哨兵 0（不是“现在”），不得冒充刚读过。
  group('advanceUpdatedAt: false（无痕阅读冻结 History 时间戳）', () {
    test('existing row keeps updatedAt while all position fields advance',
        () async {
      await db.upsertReaderPosition(const ReaderPositionsCompanion(
        bookUid: Value('book-incognito'),
        sectionIndex: Value(1),
        normCharOffset: Value(100),
        updatedAt: Value(1000),
      ));

      await repo.save(
        bookUid: 'book-incognito',
        sectionIndex: 4,
        normCharOffset: 4200,
        charOffset: 1234,
        advanceUpdatedAt: false,
      );

      final pos = await repo.findByBookUid('book-incognito');
      expect(pos, isNotNull);
      expect(pos!.sectionIndex, 4, reason: '续读章节必须照常更新');
      expect(pos.normCharOffset, 4200, reason: '续读位置必须照常更新');
      expect(pos.charOffset, 1234, reason: '精确锚必须照常更新');
      expect(pos.updatedAt, 1000,
          reason: 'History 时间戳冻结：已有值原样保留');
    });

    test('new row gets non-recent sentinel, not "now"', () async {
      await repo.save(
        bookUid: 'book-new-incognito',
        sectionIndex: 2,
        normCharOffset: 700,
        advanceUpdatedAt: false,
      );

      final pos = await repo.findByBookUid('book-new-incognito');
      expect(pos, isNotNull);
      expect(pos!.sectionIndex, 2);
      expect(pos.updatedAt, 0,
          reason: '新行必须用非近期哨兵，否则「最近阅读」会把它当成刚读过');
    });

    test('default save (incognito off) still advances updatedAt', () async {
      await db.upsertReaderPosition(const ReaderPositionsCompanion(
        bookUid: Value('book-normal'),
        sectionIndex: Value(0),
        normCharOffset: Value(0),
        updatedAt: Value(1),
      ));

      await repo.save(
        bookUid: 'book-normal',
        sectionIndex: 1,
        normCharOffset: 10,
      );

      final pos = await repo.findByBookUid('book-normal');
      expect(pos!.updatedAt, greaterThan(1),
          reason: '关掉无痕后必须恢复推进最近阅读');
    });
  });
}
