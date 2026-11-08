// 漫画章节下载队列（v103）：在线漫画「先下载再读」的持久化任务表，
// 单 worker 串行取任务。表语义见 tables.dart 的 MangaDownloadJobs。
part of 'database.dart';

mixin _FushiDbMangaDownload on _$FushiDatabase {
  /// 按主键 upsert 一条任务。同章重复入队（job_id 由 kind/bookKey/chapterKey
  /// 派生）落到同一行，调用方不必先查再写。
  Future<void> upsertMangaDownloadJob(MangaDownloadJobsCompanion job) =>
      into(mangaDownloadJobs).insertOnConflictUpdate(job);

  Future<MangaDownloadJobRow?> getMangaDownloadJob(String jobId) =>
      (select(mangaDownloadJobs)..where((t) => t.jobId.equals(jobId)))
          .getSingleOrNull();

  /// 按身份三元组找任务（唯一索引 `(kind, book_key, chapter_key)` 保证至多一行）。
  Future<MangaDownloadJobRow?> findMangaDownloadJob({
    required String kind,
    required String bookKey,
    required String chapterKey,
  }) =>
      (select(mangaDownloadJobs)
            ..where((t) =>
                t.kind.equals(kind) &
                t.bookKey.equals(bookKey) &
                t.chapterKey.equals(chapterKey)))
          .getSingleOrNull();

  /// 列表，按创建时刻升序（再按 job_id 兜稳定序）。[statuses] 为空 = 不过滤。
  Future<List<MangaDownloadJobRow>> listMangaDownloadJobs({
    Set<String> statuses = const <String>{},
  }) {
    final SimpleSelectStatement<$MangaDownloadJobsTable, MangaDownloadJobRow>
        query = select(mangaDownloadJobs);
    if (statuses.isNotEmpty) {
      query.where((t) => t.status.isIn(statuses));
    }
    query.orderBy(<OrderingTerm Function($MangaDownloadJobsTable)>[
      (t) => OrderingTerm(expression: t.createdAt),
      (t) => OrderingTerm(expression: t.jobId),
    ]);
    return query.get();
  }

  /// 「任务表变了」的信号流（不带行）。长驻页面订阅必须用它而不是裸
  /// `select(...).watch()`：drift 的 QueryStream 取消时会排一个 `Timer.run`，
  /// widget 测试里页面 dispose 后它仍 pending（BUG-834）。
  Stream<void> watchMangaDownloadJobs() {
    late final StreamController<void> controller;
    StreamSubscription<void>? updatesSub;
    controller = StreamController<void>(
      onListen: () {
        updatesSub = tableUpdates(
          TableUpdateQuery
              .onAllTables(<ResultSetImplementation<dynamic, dynamic>>[
            mangaDownloadJobs,
          ]),
        ).listen((_) {
          if (!controller.isClosed) controller.add(null);
        });
      },
      onCancel: () async {
        await updatesSub?.cancel();
      },
    );
    return controller.stream;
  }

  /// 写进度。返回受影响行数（0 = 任务已不存在，调用方据此停止汇报）。
  Future<int> updateMangaDownloadJobProgress(
    String jobId, {
    required int pagesDone,
    required int pagesTotal,
    required int updatedAt,
  }) =>
      (update(mangaDownloadJobs)..where((t) => t.jobId.equals(jobId))).write(
        MangaDownloadJobsCompanion(
          pagesDone: Value<int>(pagesDone),
          pagesTotal: Value<int>(pagesTotal),
          updatedAt: Value<int>(updatedAt),
        ),
      );

  /// 改状态。[lastError] 传 `null` 表示不动该列；要清空传 [clearLastError]。
  /// [completedAt] / [attemptCount] 同理只在给出时写。
  Future<int> updateMangaDownloadJobStatus(
    String jobId, {
    required String status,
    required int updatedAt,
    String? lastError,
    bool clearLastError = false,
    int? completedAt,
    int? attemptCount,
  }) =>
      (update(mangaDownloadJobs)..where((t) => t.jobId.equals(jobId))).write(
        MangaDownloadJobsCompanion(
          status: Value<String>(status),
          updatedAt: Value<int>(updatedAt),
          lastError: clearLastError
              ? const Value<String?>(null)
              : (lastError == null
                  ? const Value<String?>.absent()
                  : Value<String?>(lastError)),
          completedAt: completedAt == null
              ? const Value<int?>.absent()
              : Value<int?>(completedAt),
          attemptCount: attemptCount == null
              ? const Value<int>.absent()
              : Value<int>(attemptCount),
        ),
      );

  Future<int> deleteMangaDownloadJob(String jobId) =>
      (delete(mangaDownloadJobs)..where((t) => t.jobId.equals(jobId))).go();

  /// 删除某种任务类型的全部任务行。启动时用来清理已移除功能的旧任务。
  Future<int> deleteMangaDownloadJobsOfKind(String kind) =>
      (delete(mangaDownloadJobs)..where((t) => t.kind.equals(kind))).go();

  /// 删一本书的全部任务行（删书 / 移出书架时随 `deleteEpubBook` 级联；旧 mokuro
  /// 卷的 `book_key` 不与任何书行同键，且启动时会被清理）。
  Future<int> deleteMangaDownloadJobsForBook(String bookKey) =>
      (delete(mangaDownloadJobs)..where((t) => t.bookKey.equals(bookKey))).go();

  /// 启动时把上次进程死亡留下的 `running` 复位成 `queued`，让 worker 续跑。
  /// 进度列不动：worker 重跑时按磁盘上已落地的页决定从哪续。
  Future<int> resetRunningMangaDownloadJobs({required int updatedAt}) =>
      (update(mangaDownloadJobs)
            ..where((t) => t.status.equals(MangaDownloadJobStatus.running)))
          .write(MangaDownloadJobsCompanion(
        status: const Value<String>(MangaDownloadJobStatus.queued),
        updatedAt: Value<int>(updatedAt),
      ));

  /// 是否存在暂停任务（= 全局暂停生效中）。暂停状态持久化在任务行上，重启后
  /// 仍能据此判定「暂停期间新入队的章节保持暂停」。
  Future<bool> hasPausedMangaDownloadJobs() async {
    final MangaDownloadJobRow? row = await (select(mangaDownloadJobs)
          ..where((t) => t.status.equals(MangaDownloadJobStatus.paused))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  /// 把**仍在 `running`** 的任务落到 `paused`。
  ///
  /// 暂停收尾专用：与「全部继续」竞态时，用户已经把行改回 `queued` 的不能再被
  /// 迟到的暂停收尾覆盖回 `paused`（否则任务永远停在暂停态）。返回 0 = 行已
  /// 被恢复 / 取消 / 删除，调用方无需别的处理。
  Future<int> pauseRunningMangaDownloadJob(
    String jobId, {
    required int updatedAt,
  }) =>
      (update(mangaDownloadJobs)
            ..where((t) =>
                t.jobId.equals(jobId) &
                t.status.equals(MangaDownloadJobStatus.running)))
          .write(MangaDownloadJobsCompanion(
        status: const Value<String>(MangaDownloadJobStatus.paused),
        updatedAt: Value<int>(updatedAt),
      ));

  /// 全局暂停：把排队中 / 下载中的任务置为 `paused`。`failed` / `done` 等
  /// 其它状态不动。返回受影响行数。
  Future<int> pauseQueuedAndRunningMangaDownloadJobs({
    required int updatedAt,
  }) =>
      (update(mangaDownloadJobs)
            ..where(
              (t) => t.status.isIn(MangaDownloadJobStatus.queuedOrRunning),
            ))
          .write(MangaDownloadJobsCompanion(
        status: const Value<String>(MangaDownloadJobStatus.paused),
        updatedAt: Value<int>(updatedAt),
      ));

  /// 全局继续：暂停任务恢复为排队，并重试全部失败任务（复位尝试次数、清错误）。
  /// 两段在同一事务里完成，页面不会观察到「一半暂停一半排队」的中间态。
  Future<void> resumePausedAndRetryFailedMangaDownloadJobs({
    required int updatedAt,
  }) =>
      transaction(() async {
        await (update(mangaDownloadJobs)
              ..where((t) => t.status.equals(MangaDownloadJobStatus.paused)))
            .write(MangaDownloadJobsCompanion(
          status: const Value<String>(MangaDownloadJobStatus.queued),
          updatedAt: Value<int>(updatedAt),
        ));
        await (update(mangaDownloadJobs)
              ..where((t) => t.status.equals(MangaDownloadJobStatus.failed)))
            .write(MangaDownloadJobsCompanion(
          status: const Value<String>(MangaDownloadJobStatus.queued),
          updatedAt: Value<int>(updatedAt),
          attemptCount: const Value<int>(0),
          lastError: const Value<String?>(null),
        ));
      });

  /// 事务内取最早的 `queued` 任务置为 `running` 并返回置后的行；队列空返回 null。
  /// 单 worker 场景下事务只是防「取到与置状态之间被另一条 upsert 改掉」。
  Future<MangaDownloadJobRow?> claimNextQueuedMangaDownloadJob({
    required int updatedAt,
  }) =>
      transaction(() async {
        final MangaDownloadJobRow? next = await (select(mangaDownloadJobs)
              ..where((t) => t.status.equals(MangaDownloadJobStatus.queued))
              ..orderBy(<OrderingTerm Function($MangaDownloadJobsTable)>[
                (t) => OrderingTerm(expression: t.createdAt),
                (t) => OrderingTerm(expression: t.jobId),
              ])
              ..limit(1))
            .getSingleOrNull();
        if (next == null) return null;
        final int changed = await (update(mangaDownloadJobs)
              ..where((t) =>
                  t.jobId.equals(next.jobId) &
                  t.status.equals(MangaDownloadJobStatus.queued)))
            .write(MangaDownloadJobsCompanion(
          status: const Value<String>(MangaDownloadJobStatus.running),
          updatedAt: Value<int>(updatedAt),
        ));
        if (changed == 0) return null;
        return next.copyWith(
          status: MangaDownloadJobStatus.running,
          updatedAt: updatedAt,
        );
      });

  // ── Download library 章目录映射（票 04） ──────────────────────────

  /// 记录/更新 `(bookKey, chapterKey)` 的实际容器名与容器类型。
  ///
  /// 下载完成后、目录 rename / 压缩包落位成功后才写；重建索引按 `pages.json`
  /// 的稳定 ID 重新关联时也走这里。[containerKind] 取
  /// [MangaChapterContainerKind]，默认 folder 保持旧调用点语义；写库时在这里
  /// 统一转成持久化字符串（TEXT 列）。
  Future<void> upsertMangaChapterDir({
    required String bookKey,
    required String chapterKey,
    required String folderName,
    MangaChapterContainerKind containerKind =
        MangaChapterContainerKind.folder,
    required int updatedAt,
  }) =>
      into(mangaChapterDirs).insertOnConflictUpdate(
        MangaChapterDirsCompanion.insert(
          bookKey: bookKey,
          chapterKey: chapterKey,
          folderName: folderName,
          containerKind: Value<String>(containerKind.storageValue),
          updatedAt: updatedAt,
        ),
      );

  Future<MangaChapterDirRow?> getMangaChapterDir(
    String bookKey,
    String chapterKey,
  ) =>
      (select(mangaChapterDirs)
            ..where((t) =>
                t.bookKey.equals(bookKey) & t.chapterKey.equals(chapterKey)))
          .getSingleOrNull();

  /// 一本书的全部映射（chapterKey → folderName）。
  Future<Map<String, String>> getMangaChapterDirNamesForBook(
    String bookKey,
  ) async {
    final List<MangaChapterDirRow> rows = await (select(mangaChapterDirs)
          ..where((t) => t.bookKey.equals(bookKey)))
        .get();
    return <String, String>{
      for (final MangaChapterDirRow row in rows) row.chapterKey: row.folderName,
    };
  }

  /// 一本书的全部映射行（chapterKey → 行；含 `containerKind`，供重建/互联区分
  /// 文件夹与压缩包）。
  Future<Map<String, MangaChapterDirRow>> getMangaChapterDirRowsForBook(
    String bookKey,
  ) async {
    final List<MangaChapterDirRow> rows = await (select(mangaChapterDirs)
          ..where((t) => t.bookKey.equals(bookKey)))
        .get();
    return <String, MangaChapterDirRow>{
      for (final MangaChapterDirRow row in rows) row.chapterKey: row,
    };
  }

  /// 全部章节容器映射（书架「是否已下载」批量判定；一次查询，不随书数增长）。
  Future<List<MangaChapterDirRow>> getAllMangaChapterDirRows() =>
      select(mangaChapterDirs).get();

  Future<int> deleteMangaChapterDir(String bookKey, String chapterKey) =>
      (delete(mangaChapterDirs)
            ..where((t) =>
                t.bookKey.equals(bookKey) & t.chapterKey.equals(chapterKey)))
          .go();

  Future<int> deleteMangaChapterDirsForBook(String bookKey) =>
      (delete(mangaChapterDirs)..where((t) => t.bookKey.equals(bookKey))).go();
}

/// `manga_chapter_dirs.container_kind` 以 TEXT 持久化；读取时在数据库边界转成
/// [MangaChapterContainerKind]，调用方不再直接比较裸字符串。
extension MangaChapterDirRowContainerKind on MangaChapterDirRow {
  MangaChapterContainerKind get containerKindEnum =>
      MangaChapterContainerKind.fromStorage(containerKind);
}
