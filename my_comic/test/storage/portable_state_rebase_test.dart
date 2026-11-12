import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic_core/my_comic_core.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_comic/src/media/media_source.dart' show dbSourcePrefKey;
import 'package:my_comic/src/media/sources/reader_my_comic_source.dart'
    show kReaderSourcePersistedKey;
import 'package:my_comic/src/storage/app_paths.dart';
import 'package:my_comic/src/storage/portable_state_rebase.dart';

/// Ticket 02：Portable copy 启动时的路径 rebase。
///
/// 场景：整份程序目录（含 `userdata`）被拷到另一个 Windows 用户 / 另一台机器。
/// 启动后：
///  - 记录里的旧用户默认 `Documents\MyComic` 自动换成当前用户的默认根；
///  - `epub_books.extract_dir` 等 Content root 绝对路径跟着改；
///  - 自定义字体等 state 内绝对路径跟着新的 Program state root 改；
///  - 文件在则章节可读，不在则由章节状态（done 任务 + 磁盘判据）显示 Missing。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory platformDocuments;
  late Directory installDir;
  late Directory localAppData;

  String currentDefaultContentRoot() =>
      p.join(platformDocuments.path, 'MyComic');

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('my_comic_portable_rebase_');
    platformDocuments = Directory(p.join(tmp.path, 'Users', 'bob', 'Documents'))
      ..createSync(recursive: true);
    installDir = Directory(p.join(tmp.path, 'Program', 'MyComic'))
      ..createSync(recursive: true);
    localAppData = Directory(p.join(tmp.path, 'LocalAppData'))
      ..createSync(recursive: true);
    AppPaths.debugExecutablePathOverride = p.join(
      installDir.path,
      'my_comic.exe',
    );
    AppPaths.debugLocalAppDataOverride = localAppData.path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async {
            switch (call.method) {
              case 'getApplicationDocumentsDirectory':
                return platformDocuments.path;
              case 'getApplicationSupportDirectory':
                return p.join(tmp.path, 'default_support');
              case 'getTemporaryDirectory':
                return p.join(tmp.path, 'systemp');
            }
            return null;
          },
        );
  });

  tearDown(() {
    AppPaths.debugExecutablePathOverride = null;
    AppPaths.debugLocalAppDataOverride = null;
    AppPaths.forceDefaultRootForSession = false;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('旧用户默认 Content root 自动 rebase，state 内字体路径也随程序目录改', () async {
    final Directory oldDefault = Directory(
      p.join(tmp.path, 'Users', 'alice', 'Documents', 'MyComic'),
    )..createSync(recursive: true);
    final Directory oldState = Directory(
      p.join(tmp.path, 'OldProgram', 'userdata', 'state'),
    )..createSync(recursive: true);
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppPaths.contentRootPrefKey: oldDefault.path,
    });

    final AppPaths paths = await AppPaths.resolve();
    final MyComicDatabase db = MyComicDatabase(paths.stateRoot.path);
    addTearDown(db.close);

    const String bookKey = 'book-portable';
    const String chapterKey = 'chapter-present';
    final String oldBookDir = p.join(oldDefault.path, 'my_comic_books', bookKey);
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'Portable Manga',
        epubPath: 'manga.json',
        extractDir: oldBookDir,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1,
        format: const Value<String>('manga'),
      ),
    );
    final String fontPrefKey = dbSourcePrefKey(
      kReaderSourcePersistedKey,
      'font_catalog',
    );
    await db.setPref(
      fontPrefKey,
      jsonEncode(<String, Object?>{
        'version': 1,
        'fonts': <Object?>[
          <String, Object?>{
            'id': 'font_1',
            'name': 'Klee',
            'path': p.join(oldState.path, 'custom_fonts', 'Klee.ttf'),
          },
        ],
      }),
    );
    await db.setPref(
      PortableStateRebase.lastContentRootPrefKey,
      oldDefault.path,
    );
    await db.setPref(PortableStateRebase.lastStateRootPrefKey, oldState.path);

    // 便携拷贝时用户手动把 content 一起带过来：文件在 → 章节可读。
    final String newBookDir = p.join(
      currentDefaultContentRoot(),
      'my_comic_books',
      bookKey,
    );
    final Directory chapterDir = Directory(
      p.join(newBookDir, 'chapters', 'fixture-chapter'),
    );
    Directory(p.join(chapterDir.path, 'images')).createSync(recursive: true);
    File(p.join(chapterDir.path, 'manga.json')).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'pages': <Object?>[
          <String, Object?>{
            'url': 'images/page-000001.jpg',
            'width': 1,
            'height': 1,
          },
        ],
      }),
    );
    File(
      p.join(chapterDir.path, 'images', 'page-000001.jpg'),
    ).writeAsBytesSync(<int>[1, 2, 3]);

    final PortableStateRebaseOutcome outcome =
        await PortableStateRebase.reconcile(
          db: db,
          paths: paths,
          staleContentRoot: paths.contentRootRebaseFrom,
        );

    final EpubBookRow? book = await db.getEpubBook(bookKey);
    expect(
      book!.extractDir,
      newBookDir,
      reason: 'Content root 绝对路径必须改到当前用户默认根',
    );
    expect(
      File(
        p.join(book.extractDir, 'chapters', 'fixture-chapter', 'manga.json'),
      ).existsSync(),
      isTrue,
      reason: '文件在 → 下载恢复',
    );

    final Map<String, dynamic> catalog =
        jsonDecode((await db.getPref(fontPrefKey))!) as Map<String, dynamic>;
    final String fontPath =
        ((catalog['fonts'] as List<dynamic>).first
                as Map<String, dynamic>)['path']
            as String;
    expect(
      fontPath,
      p.join(paths.customFontsRoot.path, 'Klee.ttf'),
      reason: '自定义字体路径必须从旧 Program state root 改到新 state root',
    );

    expect(outcome.error, isNull);
    expect(outcome.booksRebased, 1);
    expect(outcome.rebased, isTrue);
    expect(
      await db.getPref(PortableStateRebase.lastContentRootPrefKey),
      paths.contentRoot.path,
    );
    expect(
      await db.getPref(PortableStateRebase.lastStateRootPrefKey),
      paths.stateRoot.path,
    );
  });

  test('文件不在时保持当前根路径，章节状态由 done 任务 + 磁盘判据得到 Missing', () async {
    final Directory oldDefault = Directory(
      p.join(tmp.path, 'Users', 'alice', 'Documents', 'MyComic'),
    )..createSync(recursive: true);
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppPaths.contentRootPrefKey: oldDefault.path,
    });

    final AppPaths paths = await AppPaths.resolve();
    final MyComicDatabase db = MyComicDatabase(paths.stateRoot.path);
    addTearDown(db.close);

    const String bookKey = 'book-missing';
    const String chapterKey = 'chapter-missing';
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'Missing Manga',
        epubPath: 'manga.json',
        extractDir: p.join(oldDefault.path, 'my_comic_books', bookKey),
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1,
        format: const Value<String>('manga'),
      ),
    );
    await db.upsertMangaDownloadJob(
      MangaDownloadJobsCompanion.insert(
        jobId: 'job-missing',
        kind: MangaDownloadJobKind.chapter,
        bookKey: bookKey,
        chapterKey: chapterKey,
        runtime: 'mihon',
        title: 'Missing Manga',
        chapterTitle: 'Chapter 1',
        status: const Value<String>(MangaDownloadJobStatus.done),
        createdAt: 1,
        updatedAt: 2,
      ),
    );
    await db.setPref(
      PortableStateRebase.lastContentRootPrefKey,
      oldDefault.path,
    );

    await PortableStateRebase.reconcile(
      db: db,
      paths: paths,
      staleContentRoot: paths.contentRootRebaseFrom,
    );

    final EpubBookRow book = (await db.getEpubBook(bookKey))!;
    expect(
      book.extractDir,
      p.join(currentDefaultContentRoot(), 'my_comic_books', bookKey),
      reason: '即使文件不在也 rebase 路径；缺失显示 Missing，不偷偷回读旧根',
    );
    expect(Directory(book.extractDir).existsSync(), isFalse);
    final MangaDownloadJobRow job = (await db.getMangaDownloadJob(
      'job-missing',
    ))!;
    expect(
      job.status,
      MangaDownloadJobStatus.done,
      reason: 'done 任务保留「曾经下载过」的事实，交给章节状态显示 Missing',
    );
  });

  test('没有 ledger 时也能从旧默认布局反推并 rebase（升级后的便携拷贝）', () async {
    final Directory oldDefault = Directory(
      p.join(tmp.path, 'Users', 'alice', 'Documents', 'MyComic'),
    )..createSync(recursive: true);
    final AppPaths paths = await AppPaths.resolve();
    final MyComicDatabase db = MyComicDatabase(paths.stateRoot.path);
    addTearDown(db.close);

    const String bookKey = 'book-derived';
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'Derived Manga',
        epubPath: 'manga.json',
        extractDir: p.join(oldDefault.path, 'my_comic_books', bookKey),
        chapterCount: 0,
        chaptersJson: '[]',
        importedAt: 1,
        format: const Value<String>('manga'),
      ),
    );

    final PortableStateRebaseOutcome outcome =
        await PortableStateRebase.reconcile(
          db: db,
          paths: paths,
          staleContentRoot: null,
        );

    final EpubBookRow book = (await db.getEpubBook(bookKey))!;
    expect(
      book.extractDir,
      p.join(currentDefaultContentRoot(), 'my_comic_books', bookKey),
    );
    expect(outcome.rebased, isTrue);
  });

  test('当前使用自定义 Content root 时不做旧默认根的自动 rebase（切换根语义）', () async {
    final Directory oldDefault = Directory(
      p.join(tmp.path, 'Users', 'alice', 'Documents', 'MyComic'),
    )..createSync(recursive: true);
    final Directory customContent = Directory(p.join(tmp.path, 'D', 'MyManga'))
      ..createSync(recursive: true);
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppPaths.contentRootPrefKey: customContent.path,
    });

    final AppPaths paths = await AppPaths.resolve();
    final MyComicDatabase db = MyComicDatabase(paths.stateRoot.path);
    addTearDown(db.close);

    const String bookKey = 'book-custom';
    final String oldBookDir = p.join(oldDefault.path, 'my_comic_books', bookKey);
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'Custom Manga',
        epubPath: 'manga.json',
        extractDir: oldBookDir,
        chapterCount: 0,
        chaptersJson: '[]',
        importedAt: 1,
        format: const Value<String>('manga'),
      ),
    );
    await db.setPref(
      PortableStateRebase.lastContentRootPrefKey,
      oldDefault.path,
    );

    final PortableStateRebaseOutcome outcome =
        await PortableStateRebase.reconcile(
          db: db,
          paths: paths,
          staleContentRoot: paths.contentRootRebaseFrom,
        );

    final EpubBookRow book = (await db.getEpubBook(bookKey))!;
    expect(
      book.extractDir,
      oldBookDir,
      reason: '用户切到自定义根时不自动搬/改写旧默认根路径；旧下载显示 Missing',
    );
    expect(outcome.booksRebased, 0);
    expect(
      await db.getPref(PortableStateRebase.lastContentRootPrefKey),
      customContent.path,
    );
  });

  test('没有 ledger 时也能从字体路径反推旧 state 根并 rebase', () async {
    final AppPaths paths = await AppPaths.resolve();
    final MyComicDatabase db = MyComicDatabase(paths.stateRoot.path);
    addTearDown(db.close);
    final Directory oldState = Directory(
      p.join(tmp.path, 'OldProgram', 'userdata', 'state'),
    )..createSync(recursive: true);
    final String fontPrefKey = dbSourcePrefKey(
      kReaderSourcePersistedKey,
      'font_catalog',
    );
    await db.setPref(
      fontPrefKey,
      jsonEncode(<String, Object?>{
        'version': 1,
        'fonts': <Object?>[
          <String, Object?>{
            'id': 'font_1',
            'name': 'Klee',
            'path': p.join(oldState.path, 'custom_fonts', 'Klee.ttf'),
          },
        ],
      }),
    );

    await PortableStateRebase.reconcile(
      db: db,
      paths: paths,
      staleContentRoot: null,
    );

    final Map<String, dynamic> catalog =
        jsonDecode((await db.getPref(fontPrefKey))!) as Map<String, dynamic>;
    final String fontPath =
        ((catalog['fonts'] as List<dynamic>).first
                as Map<String, dynamic>)['path']
            as String;
    expect(
      fontPath,
      p.join(paths.customFontsRoot.path, 'Klee.ttf'),
      reason: '反推出的旧根必须包含 state 段，不能多套一层 state/state',
    );
  });

  test('reconcile 失败不抛出（启动可继续），并报告 error', () async {
    final AppPaths paths = await AppPaths.resolve();
    final MyComicDatabase db = MyComicDatabase(paths.stateRoot.path);
    addTearDown(db.close);
    PortableStateRebase.debugFailBeforeRebase = true;
    addTearDown(() => PortableStateRebase.debugFailBeforeRebase = false);

    final PortableStateRebaseOutcome outcome =
        await PortableStateRebase.reconcile(
          db: db,
          paths: paths,
          staleContentRoot: null,
        );

    expect(outcome.error, isNotNull);
    expect(outcome.rebased, isFalse);
  });
}
