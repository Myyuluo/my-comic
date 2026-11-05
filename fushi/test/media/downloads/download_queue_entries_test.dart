import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart';
import 'package:fushi/src/media/discovery/discovery_download_tasks_section.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/media/downloads/manga_download_tasks_section.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi_core/fushi_core.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    ),
  );
}

/// 不 start 的服务：行停在 queued，状态由测试直接写表。时钟单调递增，让
/// `created_at` 与入队顺序一致（同毫秒入队会退化成按 job_id 哈希排序）。
MangaDownloadService _service(FushiDatabase db) {
  int tick = 0;
  return MangaDownloadService(
    database: db,
    serviceFor: (_) => throw UnimplementedError('本测试不跑 worker'),
    clock: () => DateTime.fromMillisecondsSinceEpoch(++tick),
  );
}

/// 直接写一条章节任务行：本组测试只关心任务中心的映射与分组，不跑 worker。
Future<void> _insertMangaJob(
  FushiDatabase db, {
  required String jobId,
  required String bookKey,
  required String chapterKey,
  required String title,
  required String chapterTitle,
  required int createdAt,
}) => db.upsertMangaDownloadJob(
  MangaDownloadJobsCompanion.insert(
    jobId: jobId,
    kind: MangaDownloadJobKind.chapter,
    bookKey: bookKey,
    chapterKey: chapterKey,
    runtime: 'mihon',
    title: title,
    chapterTitle: chapterTitle,
    status: const Value<String>(MangaDownloadJobStatus.queued),
    pagesDone: const Value<int>(0),
    pagesTotal: const Value<int>(0),
    attemptCount: const Value<int>(0),
    autoOcr: const Value<bool>(false),
    createdAt: createdAt,
    updatedAt: createdAt,
  ),
);

void main() {
  test(
    'manga selective cleanup removes only that row and keeps the others',
    () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      final MangaDownloadService service = _service(db);
      addTearDown(() async {
        service.dispose();
        await db.close();
      });
      for (int i = 1; i <= 3; i++) {
        await _insertMangaJob(
          db,
          jobId: 'job-$i',
          bookKey: 'series',
          chapterKey: '0$i',
          title: 'Series',
          chapterTitle: '0$i',
          createdAt: i,
        );
      }
      final List<MangaDownloadJobRow> rows = await service.listJobs();
      final MangaDownloadJobRow running = rows[0];
      final MangaDownloadJobRow removed = rows[1];
      final MangaDownloadJobRow retained = rows[2];
      await db.updateMangaDownloadJobStatus(
        running.jobId,
        status: MangaDownloadJobStatus.running,
        updatedAt: 1,
      );
      await db.updateMangaDownloadJobStatus(
        removed.jobId,
        status: MangaDownloadJobStatus.done,
        updatedAt: 1,
      );
      await db.updateMangaDownloadJobStatus(
        retained.jobId,
        status: MangaDownloadJobStatus.failed,
        updatedAt: 1,
      );
      await service.remove(removed.jobId);
      expect(
        (await service.listJobs())
            .map((MangaDownloadJobRow r) => r.jobId)
            .toList(),
        <String>[running.jobId, retained.jobId],
      );
      // 再删一次是空操作，不影响其它行。
      await service.remove(removed.jobId);
      expect(await service.listJobs(), hasLength(2));
    },
  );

  testWidgets(
    'direct builder includes empty queue, kinds and stable enqueue metadata',
    (WidgetTester tester) async {
      final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
        resolvePayload: (DiscoveryResourceItem item) =>
            Completer<DiscoveryPayload>().future,
        importer: (DiscoveryDownloadTask task, File file) async =>
            const DiscoveryImportOutcome(),
      );
      addTearDown(queue.dispose);
      List<DownloadTaskEntry>? entries;
      await _pump(
        tester,
        DiscoveryDownloadTasksSection(
          queueOverride: queue,
          tasksBuilder: (BuildContext context, List<DownloadTaskEntry> tasks) {
            entries = tasks;
            return const SizedBox();
          },
        ),
      );
      expect(entries, isEmpty);
      final int before = DateTime.now().millisecondsSinceEpoch;
      for (final DiscoveryMediaKind kind in DiscoveryMediaKind.values) {
        queue.enqueue(
          DiscoveryResourceItem(
            id: kind.name,
            sourceId: 'source',
            title: 'Shared title Vol 1',
            kind: kind,
            payloadKind: DiscoveryPayloadKind.httpFile,
            payload: const DiscoveryHttpPayload(
              url: 'https://example.com/file',
            ),
          ),
          destinationDir: '',
        );
      }
      await tester.pump();
      expect(entries, hasLength(4));
      expect(
        entries!.map((DownloadTaskEntry entry) => entry.kind),
        <DownloadTaskKind>[
          DownloadTaskKind.novel,
          DownloadTaskKind.audiobook,
          DownloadTaskKind.game,
          DownloadTaskKind.manga,
        ],
      );
      expect(entries!.first.status, DownloadTaskStatus.active);
      expect(entries!.last.status, DownloadTaskStatus.queued);
      expect(
        entries!.every(
          (DownloadTaskEntry entry) => entry.collectionKey == null,
        ),
        isTrue,
      );
      expect(entries!.first.createdAt, greaterThanOrEqualTo(before));
      expect(entries!.first.actions.clear, isNull);
      expect(entries!.first.actions.retry, isNull);
      final String originalId = entries!.last.id;
      final int? originalCreatedAt = entries!.last.createdAt;
      queue.tasks.last.status = DiscoveryDownloadStatus.failed;
      queue.retry(queue.tasks.last);
      await tester.pump();
      expect(entries!.last.id, originalId);
      expect(entries!.last.createdAt, originalCreatedAt);
      queue.tasks.last.status = DiscoveryDownloadStatus.failed;
      await _pump(
        tester,
        DiscoveryDownloadTasksSection(
          queueOverride: queue,
          tasksBuilder: (BuildContext context, List<DownloadTaskEntry> tasks) {
            entries = tasks;
            return const SizedBox();
          },
        ),
      );
      expect(entries!.last.actions.retry, isNotNull);
      await entries!.last.actions.clear!();
      await tester.pump();
      expect(queue.tasks, hasLength(3));
      expect(queue.tasks.first.status, DiscoveryDownloadStatus.running);

      final BuildContext context = tester.element(find.byType(Scaffold));
      expect(entries!.first.builder(context), isA<DownloadTaskCard>());
    },
  );

  testWidgets(
    'manga groups exact series by bookKey',
    (WidgetTester tester) async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      final MangaDownloadService service = _service(db);
      addTearDown(() async {
        service.dispose();
        await db.close();
      });
      List<DownloadTaskEntry>? entries;
      await _pump(
        tester,
        MangaDownloadTasksSection(
          downloadsOverride: service,
          tasksBuilder: (BuildContext context, List<DownloadTaskEntry> tasks) {
            entries = tasks;
            return const SizedBox();
          },
        ),
      );
      await tester.pump();
      expect(entries, isEmpty);
      await _insertMangaJob(
        db,
        jobId: 'series-01',
        bookKey: 'series',
        chapterKey: '01',
        title: 'Series',
        chapterTitle: '01',
        createdAt: 1,
      );
      await _insertMangaJob(
        db,
        jobId: 'series-02',
        bookKey: 'series',
        chapterKey: '02',
        title: 'Series',
        chapterTitle: '02',
        createdAt: 2,
      );
      await _insertMangaJob(
        db,
        jobId: 'series-special-01',
        bookKey: 'series-special',
        chapterKey: '01',
        title: 'Series Special',
        chapterTitle: '01',
        createdAt: 3,
      );
      await tester.pump();
      expect(entries, hasLength(3));
      expect(entries![0].collectionKey, entries![1].collectionKey);
      expect(entries![0].collectionKey, isNot(entries![2].collectionKey));
      expect(entries![0].collectionKey, 'series');
      expect(entries![0].collectionTitle, 'Series');
      expect(entries![2].collectionTitle, 'Series Special');
      expect(entries![0].kind, DownloadTaskKind.manga);
      expect(entries![0].status, DownloadTaskStatus.queued);
      expect(entries![0].actions.cancel, isNotNull);
      expect(entries![0].actions.retry, isNull);
      expect(entries![0].actions.clear, isNull);

      final BuildContext context = tester.element(find.byType(Scaffold));
      expect(entries!.first.builder(context), isA<DownloadTaskCard>());
    },
  );
}
