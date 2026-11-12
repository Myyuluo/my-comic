import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_comic_core/my_comic_core.dart';
import 'package:my_comic/src/media/manga/library/manga_chapter_list.dart';
import 'package:my_comic/src/media/manga/library/online_manga_library_entry.dart';
import 'package:my_comic/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:my_comic/utils.dart';

/// 漫画在线源 / 下载失败给用户看的文案一律归一，原始异常串只留给诊断。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  const String rawLookup =
      "SocketException: Failed host lookup: 'example.org' "
      '(OS Error: No address associated with hostname, errno = 7)';

  group('OnlineMangaUnavailable.userMessage', () {
    test('message 是 cause 原串时按 cause 归一，原串仍留在 message / 诊断', () {
      const SocketException cause = SocketException('Failed host lookup');
      final OnlineMangaUnavailable error = OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        '$cause',
        cause: cause,
        stage: 'pages',
      );
      expect(error.userMessage, t.online_source_error_network);
      expect(error.message, '$cause');
      expect(error.diagnostics, contains('Failed host lookup'));
    });

    test('无 cause 的原始串按文本归一', () {
      const OnlineMangaUnavailable error = OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        'Exception: TimeoutException after 0:00:30.000000',
      );
      expect(error.userMessage, t.online_source_error_timeout);
    });

    test('包装方专门写的说明优先于 cause 原串', () {
      final OnlineMangaUnavailable error = OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        'The peer has not downloaded this chapter yet',
        cause: Exception('HTTP 404'),
      );
      expect(error.userMessage, 'The peer has not downloaded this chapter yet');
    });

    test('sourceDisabled 映射为中文安装指引，不露英文内部错误', () {
      LocaleSettings.setLocale(AppLocale.zhCn);
      const OnlineMangaUnavailable error = OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.sourceDisabled,
        'The manga source is missing or disabled',
      );
      expect(error.userMessage, t.online_source_error_source_disabled);
      expect(error.userMessage, '来源未安装，请先安装对应扩展后重试');
      expect(error.userMessage, isNot(contains('manga source')));
      // 原始英文只留在可复制诊断里。
      expect(
        error.diagnostics,
        contains('The manga source is missing or disabled'),
      );
    });
  });

  group('下载失败文案', () {
    test('原始异常串归一后再拼「失败 · 原因」', () {
      expect(
        mangaChapterDownloadFailedLabel(rawLookup),
        '${t.manga_chapter_download_status_failed} · '
        '${t.online_source_error_network}',
      );
      expect(
        mangaChapterDownloadFailedLabel(
          'OnlineMangaUnavailable(OnlineMangaUnavailableReason.runtimeFailure):'
          ' Exception: Log in via WebView to read',
        ),
        '${t.manga_chapter_download_status_failed} · '
        'Log in via WebView to read',
      );
    });

    test('sourceDisabled 持久化原始串（章节下载失败）归一为中文安装指引', () {
      LocaleSettings.setLocale(AppLocale.zhCn);
      const String missing =
          'OnlineMangaUnavailable(OnlineMangaUnavailableReason.sourceDisabled):'
          ' The manga source is missing or disabled';
      expect(
        mangaChapterDownloadFailedLabel(missing),
        '${t.manga_chapter_download_status_failed} · '
        '${t.online_source_error_source_disabled}',
      );
      expect(
        mangaChapterDownloadFailedLabel(missing),
        contains('来源未安装，请先安装对应扩展后重试'),
      );
      expect(
        mangaChapterDownloadFailedLabel(missing),
        isNot(contains('manga source')),
      );
      // 扩展被停用 / 卸载时桥接层写的是另一句英文，同样要归一。
      expect(
        mangaChapterDownloadFailedLabel(
          'OnlineMangaUnavailable(OnlineMangaUnavailableReason.sourceDisabled):'
          ' MihonRuntimeException(EXTENSION_DISABLED): The manga source '
          'extension is not installed or is disabled',
        ),
        contains(t.online_source_error_source_disabled),
      );
    });

    test('原因为空只给「失败」', () {
      expect(
        mangaChapterDownloadFailedLabel(null),
        t.manga_chapter_download_status_failed,
      );
      expect(
        mangaChapterDownloadFailedLabel('  '),
        t.manga_chapter_download_status_failed,
      );
    });

    testWidgets('章节列表的失败行不露原始异常串', (WidgetTester tester) async {
      const OnlineMangaChapter chapter = OnlineMangaChapter(
        key: '/c/1',
        name: 'Chapter 1',
        number: 1,
        raw: <String, Object?>{},
      );
      const OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
        runtime: OnlineMangaRuntimeKind.mihon,
        extensionPackage: 'org.example.fixture',
        sourceId: '1',
        series: OnlineMangaSeries(
          key: '/s',
          title: 'Fixture',
          raw: <String, Object?>{},
        ),
        chapters: <OnlineMangaChapter>[chapter],
      );
      const MangaDownloadJobRow job = MangaDownloadJobRow(
        jobId: 'job-1',
        kind: 'online_chapter',
        bookKey: 'book',
        chapterKey: '/c/1',
        runtime: 'mihon',
        title: 'Fixture',
        chapterTitle: 'Chapter 1',
        status: MangaDownloadJobStatus.failed,
        pagesDone: 0,
        pagesTotal: 0,
        attemptCount: 3,
        lastError: rawLookup,
        autoOcr: false,
        createdAt: 0,
        updatedAt: 0,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MangaChapterList(
                entry: entry,
                states: const <String, MangaChapterStateRow>{},
                newestFirst: true,
                unreadOnly: false,
                onChapterTap: (OnlineMangaChapter _) {},
                jobsByChapterKey: const <String, MangaDownloadJobRow>{
                  '/c/1': job,
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.textContaining(t.online_source_error_network),
        findsOneWidget,
      );
      expect(find.textContaining('SocketException'), findsNothing);
      expect(find.textContaining('Failed host lookup'), findsNothing);
    });
  });
}
