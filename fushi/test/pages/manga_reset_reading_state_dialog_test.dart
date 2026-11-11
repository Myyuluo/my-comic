// ticket 04（漫画 UI 修正）：单卡与批量共用的「重置阅读状态」对话框只保留
// 「同时撤销最近一次打开的记录」，不再提供「同时清除它的全部学习记录」。
//
// 这里走页面级 seam（真实 37 表 FushiDatabase + 真实书架页 + 真实对话框 / 落地
// 函数），钉住两条入口的可见选项与数据结果：
//  * 单卡：勾选保留项后，阅读位置回到开头、读完标记清空、最近一次学习会话写零。
//  * 批量：不勾任何选项时，只重置位置与完成标记，学习记录原样保留。
// 底层 study_segments 写入 / 统计中心不在本文件内被删除或绕过。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

const String _bookKey = 'manga-alpha';
const String _segmentUid = 'seg-alpha';

MediaItem _bookItem(String title) => MediaItem(
      mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(_bookKey),
      title: title,
      mediaTypeIdentifier: ReaderMediaType.instance.uniqueKey,
      mediaSourceIdentifier: MangaFushiSource.kUniqueKey,
      position: 3,
      duration: 100,
      canDelete: false,
      canEdit: true,
    );

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_manga_reset_dialog_pp',
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });

  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      try {
        pathProviderDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  late FushiDatabase db;
  late AppModel appModel;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir = Directory.systemTemp.createTempSync(
      'fushi_manga_reset_dialog_store',
    );
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(
        prefsRepo: prefs,
        databaseDirectory: storeDir,
      );
    appModel.populateLanguages();
    appModel.populateMediaTypes();
    appModel.populateMediaSources();
  });

  tearDown(() async {
    await db.close();
  });

  Widget buildApp() => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
          fushiBooksProvider.overrideWith(
            (ref, language) =>
                Future<List<MediaItem>>.value(<MediaItem>[_bookItem('Alpha')]),
          ),
          srtBooksProvider.overrideWith(
            (ref) => Future<List<SrtBook>>.value(const <SrtBook>[]),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: ReaderFushiHistoryPage(
                mangaOnly: true,
              ),
            ),
          ),
        ),
      );

  Future<void> seedBook() async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: _bookKey,
        title: 'Alpha',
        epubPath: '/tmp/manga-alpha/manga.json',
        extractDir: '/tmp/manga-alpha',
        chapterCount: 1,
        chaptersJson: '["1"]',
        importedAt: now,
        format: const Value<String>('manga'),
      ),
    );
    final EpubBookRow book = (await db.getEpubBook(_bookKey))!;
    await db.upsertReaderPosition(
      ReaderPositionsCompanion.insert(
        bookUid: book.uid,
        sectionIndex: 4,
        normCharOffset: 500,
        charOffset: const Value<int>(234),
        updatedAt: now,
      ),
    );
    await db.setEpubBookCompleted(
      _bookKey,
      DateTime.fromMillisecondsSinceEpoch(now),
    );
    final DateTime segStart =
        DateTime.fromMillisecondsSinceEpoch(now - 120000);
    await db.upsertStudySegment(
      StudySegmentsCompanion.insert(
        uid: _segmentUid,
        deviceId: 'test-device',
        mediaKind: kActivityMediaBook,
        mediaKey: _bookKey,
        title: 'Alpha',
        startAt: segStart.millisecondsSinceEpoch,
        endAt: now - 60000,
        dateKey: FushiDatabase.statDateKeyOf(segStart),
        hour: segStart.hour,
        durationMs: const Value<int>(60000),
        chars: const Value<int>(321),
        pages: const Value<int>(7),
        updatedAt: now,
      ),
    );
  }

  Future<StudySegmentRow> segment() async => (await db.getStudySegments())
      .singleWhere((StudySegmentRow r) => r.uid == _segmentUid);

  Future<void> expectReadingPositionReset() async {
    final EpubBookRow book = (await db.getEpubBook(_bookKey))!;
    final ReaderPositionRow position = (await db.getReaderPosition(book.uid))!;
    expect(position.sectionIndex, 0, reason: '阅读位置回到开头');
    expect(position.normCharOffset, 0, reason: '阅读位置回到开头');
    expect(position.charOffset, -1, reason: '页式位置精确锚缺席 = 未读形状');
    expect(book.completedAt, isNull, reason: '读完标记被清空');
  }

  Finder card() => find.byKey(
        ValueKey<String>(
          'book_entry_${ReaderFushiSource.mediaIdentifierFor(_bookKey)}',
        ),
      );

  void expectOnlyRetainedOption() {
    expect(
      find.text(t.library_progress_reset_records_all),
      findsNothing,
      reason: 'ticket 04：不再显示「同时清除它的全部学习记录」',
    );
    expect(
      find.text(t.library_progress_reset_records_all_desc),
      findsNothing,
      reason: 'ticket 04：破坏性统计选项从对话框移除',
    );
    expect(
      find.text(t.library_progress_reset_records_last_session),
      findsOneWidget,
      reason: '「同时撤销最近一次打开的记录」必须保留',
    );
  }

  testWidgets('单卡：对话框只保留撤销最近一次；勾选后位置与读完清空、最近会话写零',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);

    await seedBook();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    expect(card(), findsOneWidget);

    await tester.longPress(card());
    await tester.pumpAndSettle();
    final Finder resetAction = find.text(t.library_progress_reset_action);
    await tester.ensureVisible(resetAction);
    await tester.pumpAndSettle();
    await tester.tap(resetAction);
    await tester.pumpAndSettle();

    expectOnlyRetainedOption();
    await tester.tap(find.text(t.library_progress_reset_records_last_session));
    await tester.pump();
    await tester.tap(find.text(t.library_progress_reset_confirm));
    await tester.pumpAndSettle();

    await expectReadingPositionReset();
    final StudySegmentRow after = await segment();
    expect(after.durationMs, 0, reason: '勾选后最近一次会话的时长写零');
    expect(after.chars, 0, reason: '勾选后最近一次会话的字数写零');
    expect(after.pages, 0, reason: '勾选后最近一次会话的页数写零');
  });

  testWidgets('批量：同一对话框；不勾选项时只重置位置与读完，学习记录原样保留',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);

    await seedBook();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(FushiIcons.checklist));
    await tester.pumpAndSettle();
    await tester.tap(card());
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('reader_shelf_batch_reset_progress')),
    );
    await tester.pumpAndSettle();

    expectOnlyRetainedOption();
    await tester.tap(find.text(t.library_progress_reset_confirm));
    await tester.pumpAndSettle();

    await expectReadingPositionReset();
    final StudySegmentRow after = await segment();
    expect(after.durationMs, 60000, reason: '不勾选项时学习记录不动');
    expect(after.chars, 321, reason: '不勾选项时学习记录不动');
    expect(after.pages, 7, reason: '不勾选项时学习记录不动');
  });
}
