import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/tracking/media_tracking_settings_body.dart';
import 'package:fushi_core/fushi_core.dart';

/// manga-library-membership 票 15（review finding 2）：Tracking 的「本地条目」
/// 只能列出书架成员。非书架 Manga 行持久化后仍存在，但 Tag / 订阅 / Tracking
/// 都是书架专属功能；把它们列成映射目标会让用户给非书架作品建一条永远不该
/// 存在的 Tracking。
void main() {
  late FushiDatabase db;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> insertManga({
    required String bookKey,
    required String title,
    required bool inLibrary,
  }) => db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: title,
      epubPath: '',
      extractDir: '/tmp/$bookKey',
      chapterCount: 0,
      chaptersJson: '[]',
      importedAt: 1,
      format: const Value<String>('manga'),
      inLibrary: Value<bool>(inLibrary),
    ),
  );

  test('只列出书架中的 Manga，非书架行不进入 Tracking 映射目标', () async {
    await insertManga(
      bookKey: 'library-book',
      title: 'Library work',
      inLibrary: true,
    );
    await insertManga(
      bookKey: 'non-library-book',
      title: 'Non-library work',
      inLibrary: false,
    );

    final List<MediaTrackingLocalTarget> targets =
        await loadMediaTrackingLocalTargets(db);

    expect(
      targets.map((MediaTrackingLocalTarget target) => target.key),
      <String>['library-book'],
      reason: '非书架作品不能作为 Tracking 映射目标',
    );
  });
}
