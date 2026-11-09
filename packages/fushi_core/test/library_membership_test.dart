import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:test/test.dart';

/// Library membership 是「书架归属」的唯一判据：`epub_books` 行存在不再
/// 等于在书架。阅读 / History / 下载仍然读全部行，所以数据层必须同时提供
/// 「全部行」与「书架行」两条读取口径。
void main() {
  late FushiDatabase db;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  Future<EpubBookRow> insertBook(
    String bookKey, {
    required bool inLibrary,
  }) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: bookKey,
        epubPath: 'manga.json',
        extractDir: '/tmp/$bookKey',
        chapterCount: 0,
        chaptersJson: '[]',
        importedAt: 1,
        format: const Value<String>('manga'),
        inLibrary: Value<bool>(inLibrary),
      ),
    );
    return (await db.getEpubBook(bookKey))!;
  }

  test('新插入的行默认在书架', () async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'default',
        title: 'Default',
        epubPath: 'manga.json',
        extractDir: '/tmp/default',
        chapterCount: 0,
        chaptersJson: '[]',
        importedAt: 1,
        format: const Value<String>('manga'),
      ),
    );
    expect((await db.getEpubBook('default'))!.isInLibrary, isTrue);
  });

  test('getLibraryEpubBooks 只返回书架行，getAllEpubBooks 仍返回全部行', () async {
    await insertBook('library', inLibrary: true);
    await insertBook('non-library', inLibrary: false);

    final List<EpubBookRow> library = await db.getLibraryEpubBooks();
    expect(library.map((EpubBookRow row) => row.bookKey), <String>['library']);

    final List<EpubBookRow> all = await db.getAllEpubBooks();
    expect(all.map((EpubBookRow row) => row.bookKey).toSet(), <String>{
      'library',
      'non-library',
    }, reason: '阅读 / History / 下载仍要能按身份读到非书架行');
  });
}
