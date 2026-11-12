import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_comic/src/utils/components/glass/my_comic_icon.dart';
import 'package:my_comic_core/my_comic_core.dart';
import 'package:my_comic/src/media/downloads/download_source_method.dart';
import 'package:my_comic/src/media/downloads/download_task_card.dart';
import 'package:my_comic/src/media/downloads/download_task_entry.dart';
import 'package:my_comic/src/media/manga/download/manga_download_service.dart';
import 'package:my_comic/src/media/manga/library/manga_chapter_list.dart'
    show mangaChapterDownloadFailedLabel;
import 'package:my_comic/src/models/app_model.dart';
import 'package:my_comic/utils.dart';

/// 「下载」页任务 tab 的漫画分区：读 `manga_download_jobs`（在线章节任务）输出
/// [DownloadTaskEntry]，与 torrent / 直链 / 远端任务并列进统一列表
/// （设计稿 2026-09-12 §4）。
///
/// 只做映射，不持有任务：动作全部委托 [MangaDownloadService]（取消 / 重试 /
/// 清除），行的真相是表——`watchJobs` 一响就整体重取。独立使用时空表不占位；
/// [tasksBuilder] 把条目接进外层统一列表。
///
/// 下载页只列可操作任务（ticket 05）：`done` 行保留在表里仅供作品页判
/// 「文件缺失」，取消会直接删行，因此都不进列表；`failed` 保留并同时显示
/// 「重试」与「取消」（ticket 09，取消清理任务行、staging / 临时包并 toast）。
/// `paused`（ticket 07 全局暂停）保留在列表且可单独取消；暂停 / 继续只由下载页
/// 右下角的全局按钮控制，行内不提供。
class MangaDownloadTasksSection extends ConsumerStatefulWidget {
  const MangaDownloadTasksSection({
    super.key,
    this.downloadsOverride,
    this.tasksBuilder,
    this.onTasksChanged,
  });

  /// 测试注入服务（null = 取 [AppModel.mangaDownloadService]）。
  final MangaDownloadService? downloadsOverride;

  /// Parent owns unified filtering, sorting and grouping, including empty lists.
  final DownloadTasksBuilder? tasksBuilder;

  /// 每次重新读取任务表后回调当前可见条目（下载页据此决定全局按钮状态）。
  /// 回调发生在异步 reload 完成之后，不在 build 阶段。
  final ValueChanged<List<DownloadTaskEntry>>? onTasksChanged;

  @override
  ConsumerState<MangaDownloadTasksSection> createState() =>
      _MangaDownloadTasksSectionState();
}

/// 下载页可见的任务状态：排队 / 下载中 / 暂停 / 失败。`done` 保留在表中但不再
/// 展示（作品页 Missing 判定需要它）；`cancelled` 是取消路径不再产生的遗留值，
/// 也一并隐藏。
const Set<String> _visibleJobStatuses = <String>{
  ...MangaDownloadJobStatus.active,
  MangaDownloadJobStatus.failed,
};

class _MangaDownloadTasksSectionState
    extends ConsumerState<MangaDownloadTasksSection> {
  MangaDownloadService? _downloads;
  List<MangaDownloadJobRow> _jobs = const <MangaDownloadJobRow>[];
  StreamSubscription<void>? _watch;

  @override
  void initState() {
    super.initState();
    _downloads = widget.downloadsOverride ?? _appService();
    final MangaDownloadService? downloads = _downloads;
    if (downloads == null) return;
    _watch = downloads.watchJobs().listen(
      (_) => unawaited(_reload()),
      onError: (Object error, StackTrace stack) {
        ErrorLogService.instance.log(
          'MangaDownloadTasksSection.watch',
          error,
          stack,
        );
      },
    );
    unawaited(_reload());
  }

  @override
  void dispose() {
    unawaited(_watch?.cancel());
    _watch = null;
    super.dispose();
  }

  /// Do not initialize the database-backed service when one is injected.
  MangaDownloadService? _appService() {
    final AppModel appModel = ref.read(appProvider);
    return appModel.isDatabaseReady ? appModel.mangaDownloadService : null;
  }

  Future<void> _reload() async {
    final MangaDownloadService? downloads = _downloads;
    if (downloads == null) return;
    final List<MangaDownloadJobRow> jobs = await downloads.listJobs(
      statuses: _visibleJobStatuses,
    );
    if (!mounted) return;
    setState(() => _jobs = jobs);
    widget.onTasksChanged?.call(_entriesFor(jobs, downloads));
  }

  List<DownloadTaskEntry> _entriesFor(
    List<MangaDownloadJobRow> jobs,
    MangaDownloadService downloads,
  ) => <DownloadTaskEntry>[
        for (final MangaDownloadJobRow job in jobs)
          mangaDownloadTaskEntry(job, downloads),
      ];

  @override
  Widget build(BuildContext context) {
    final MangaDownloadService? downloads = _downloads;
    final List<DownloadTaskEntry> entries = downloads == null
        ? const <DownloadTaskEntry>[]
        : _entriesFor(_jobs, downloads);
    final DownloadTasksBuilder? builder = widget.tasksBuilder;
    if (builder != null) return builder(context, entries);
    if (entries.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final DownloadTaskEntry entry in entries) entry.builder(context),
      ],
    );
  }
}

/// 一条任务行 → 统一下载中心条目。
///
/// `id = manga:<jobId>`；`collectionKey` 取 bookKey；动作：未结束可取消、
/// failed 可「继续」（同一行复位，BUG-1433）、已结束可清除。
String _mangaTaskTitle(MangaDownloadJobRow job) =>
    '${job.title} · ${job.chapterTitle}';

DownloadTaskEntry mangaDownloadTaskEntry(
  MangaDownloadJobRow job,
  MangaDownloadService downloads,
) {
  final String id = 'manga:${job.jobId}';
  final bool finished = _isFinished(job);
  // 下载页只列失败的可操作任务；取消行会被删除（遗留 cancelled 行不展示），
  // 所以行内「重试 + 取消」只服务 failed。
  final bool retryable = job.status == MangaDownloadJobStatus.failed;
  final double? progress = job.status == MangaDownloadJobStatus.done
      ? 1
      : job.pagesTotal > 0
          ? (job.pagesDone / job.pagesTotal).clamp(0.0, 1.0)
          : null;
  final String collectionTitle = job.title;
  final String status = _statusLabel(job);
  final ({DownloadTransferMethod method, bool external}) source =
      mangaDownloadSourceOf(job.runtime);
  return DownloadTaskEntry(
    id: id,
    title: _mangaTaskTitle(job),
    createdAt: job.createdAt,
    kind: DownloadTaskKind.manga,
    status: switch (job.status) {
      MangaDownloadJobStatus.queued => DownloadTaskStatus.queued,
      MangaDownloadJobStatus.running => DownloadTaskStatus.active,
      MangaDownloadJobStatus.paused => DownloadTaskStatus.paused,
      MangaDownloadJobStatus.done => DownloadTaskStatus.completed,
      MangaDownloadJobStatus.failed => DownloadTaskStatus.attention,
      _ => DownloadTaskStatus.cancelled,
    },
    progress: progress,
    collectionKey: job.bookKey,
    collectionTitle: collectionTitle,
    searchTerms: <String>[job.title, job.chapterTitle, collectionTitle],
    // 单跑道持久队列：没有调度优先级、没有暂停态（cancel 后 retry 是同一行
    // 重跑），任务上也没有可 reveal 的落盘路径。
    actions: DownloadTaskActions(
      retry: retryable ? () => downloads.retry(job.jobId) : null,
      clear: finished ? () => downloads.remove(job.jobId) : null,
      cancel: retryable
          ? () => downloads.discardFailed(job.jobId)
          : finished
              ? null
              : () => downloads.cancel(job.jobId),
    ),
    builder: (BuildContext context) {
      // 简化卡片的行尾直接操作（不再藏在展开面板里）：排队 / 下载中 / 暂停可
      // 取消；失败同时给「重试」与「取消」（ticket 09），已完成不展示。图标、
      // tooltip 与调用的 service 方法沿用原展开面板。
      final List<DownloadTaskQuickAction> quickActions =
          <DownloadTaskQuickAction>[
            if (retryable)
              DownloadTaskQuickAction(
                icon: Icons.refresh,
                tooltip: t.download_resume,
                onPressed: () => unawaited(downloads.retry(job.jobId)),
              ),
            if (retryable)
              DownloadTaskQuickAction(
                icon: Icons.close,
                tooltip: t.dialog_cancel,
                onPressed: () => unawaited(
                  _discardFailedTask(context, downloads, job.jobId),
                ),
              ),
            if (!retryable && !finished)
              DownloadTaskQuickAction(
                icon: Icons.close,
                tooltip: t.dialog_cancel,
                onPressed: () => unawaited(downloads.cancel(job.jobId)),
              ),
          ];
      return DownloadTaskCard(
        key: ValueKey<String>(id),
        taskId: id,
        // 下载页采用简化卡片：不显示来源标签、不可展开（ADR 0008 保真约束下只做
        // 减法，不新增视觉风格）。
        simplified: true,
        method: source.method,
        externalSource: source.external,
        title: job.chapterTitle,
        status: status,
        subtitle: collectionTitle,
        progress: progress,
        quickActions: quickActions,
        details: _MangaDownloadTaskRow(
          job: job,
          status: status,
          retryable: retryable,
          downloads: downloads,
        ),
      );
    },
  );
}

/// 失败行的「取消」：删除任务行与半成品（staging / 临时包 / 映射容器），成功
/// 后 toast。服务只处理 failed 行；若行已经消失则不提示。
Future<void> _discardFailedTask(
  BuildContext context,
  MangaDownloadService downloads,
  String jobId,
) async {
  final bool discarded = await downloads.discardFailed(jobId);
  if (!discarded || !context.mounted) return;
  MyComicToast.show(
    msg: t.download_task_cancel_failed,
    severity: ToastSeverity.success,
  );
}

/// 漫画下载任务的传输方式与是否外部来源（按 `runtime` 列）：Mihon 是扩展从
/// 第三方站点抓、互联是从自己已配对的设备 HTTP 拉取（不算外部来源）。未知值按
/// 扩展源处理并标外部。
({DownloadTransferMethod method, bool external}) mangaDownloadSourceOf(
  String runtime,
) =>
    switch (runtime) {
      'interconnect' => (
          method: DownloadTransferMethod.direct,
          external: false
        ),
      _ => (method: DownloadTransferMethod.extension, external: true),
    };

bool _isFinished(MangaDownloadJobRow job) =>
    MangaDownloadJobStatus.isTerminal(job.status);

String _statusLabel(MangaDownloadJobRow job) => switch (job.status) {
      MangaDownloadJobStatus.queued => t.download_status_queued,
      MangaDownloadJobStatus.paused => t.download_task_status_paused,
      MangaDownloadJobStatus.running => job.pagesTotal > 0
          ? t.manga_ocr_wizard_page_progress(
              done: job.pagesDone,
              total: job.pagesTotal,
            )
          : t.manga_chapter_download_status_downloading(
              done: '${job.pagesDone}',
              total: '${job.pagesTotal}',
            ),
      MangaDownloadJobStatus.done => t.manga_online_downloaded,
      MangaDownloadJobStatus.cancelled => t.download_status_cancelled,
      // 2026-10 体验优化：lastError 为空时原写法留下「失败: 」尾冒号；与章节列表
      // 共用同一个失败文案拼法。
      _ => mangaChapterDownloadFailedLabel(job.lastError),
    };

/// 卡片展开后的详情行：状态图标 + 标题 + 状态文案 + 行内动作。
class _MangaDownloadTaskRow extends StatelessWidget {
  const _MangaDownloadTaskRow({
    required this.job,
    required this.status,
    required this.retryable,
    required this.downloads,
  });

  final MangaDownloadJobRow job;
  final String status;

  /// failed 可「重试」并额外提供「取消」（与卡片 actions / quickActions 同一判据）。
  final bool retryable;
  final MangaDownloadService downloads;

  /// 2026-10 体验优化：20 号图标 + 默认 8 内边距只有 36dp 命中区，低于触摸
  /// 最小 48dp；手机上重试 / 取消常点空。
  static const BoxConstraints _actionTarget = BoxConstraints(
    minWidth: 48,
    minHeight: 48,
  );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool eink = isEinkTheme(context);
    final Widget statusIcon = switch (job.status) {
      MangaDownloadJobStatus.queued =>
        MyComicIcon(Icons.schedule_outlined, size: 20, color: scheme.outline),
      MangaDownloadJobStatus.paused =>
        MyComicIcon(Icons.pause_circle_outline, size: 20, color: scheme.outline),
      MangaDownloadJobStatus.done =>
        MyComicIcon(Icons.check_circle_outline, size: 20, color: scheme.primary),
      MangaDownloadJobStatus.failed =>
        MyComicIcon(Icons.error_outline, size: 20, color: scheme.error),
      MangaDownloadJobStatus.cancelled =>
        MyComicIcon(Icons.block_outlined, size: 20, color: scheme.outline),
      _ => eink
          ? const MyComicIcon(Icons.downloading_outlined, size: 20)
          : SizedBox(
              width: 20,
              height: 20,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: MyComicCircularProgressIndicator(
                  strokeWidth: 2,
                  value: job.pagesTotal > 0
                      ? (job.pagesDone / job.pagesTotal).clamp(0.0, 1.0)
                      : null,
                ),
              ),
            ),
    };
    final bool errorTone = job.status == MangaDownloadJobStatus.failed;
    return MyComicListItem(
      density: MyComicListDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      subtitleMaxLines: 2,
      titleMaxLines: 2,
      leading: statusIcon,
      title: Text(_mangaTaskTitle(job)),
      subtitle: Text(
        status,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: errorTone ? scheme.error : null,
        ),
      ),
      trailing: retryable
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                MyComicIconButton(
                  tooltip: t.download_resume,
                  icon: Icons.refresh,
                  size: 20,
                  constraints: _actionTarget,
                  onTap: () => unawaited(downloads.retry(job.jobId)),
                ),
                MyComicIconButton(
                  tooltip: t.dialog_cancel,
                  icon: Icons.close,
                  size: 20,
                  constraints: _actionTarget,
                  onTap: () => unawaited(
                    _discardFailedTask(context, downloads, job.jobId),
                  ),
                ),
              ],
            )
          : job.status == MangaDownloadJobStatus.done
              ? null
              : MyComicIconButton(
                  tooltip: t.dialog_cancel,
                  icon: Icons.close,
                  size: 20,
                  constraints: _actionTarget,
                  onTap: () => unawaited(downloads.cancel(job.jobId)),
                ),
    );
  }
}
