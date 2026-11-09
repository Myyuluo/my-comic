import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/display_title.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/online/online_source_error_text.dart';
import 'package:fushi/src/media/tags/tag_picker_sheet.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 应用级「下载完成后加入书架？」提示宿主。
///
/// 票 05 最初把提示放在 [MangaSeriesPage] 的下载状态刷新里：只有作品页打开
/// 期间观测到 job 从非 done 变 done 才提示。票 08 的非书架下载可以在作品页
/// 之外发起（下载页重试、后台队列），因此提示必须由**全局**钩子统一负责。
///
/// 宿主挂在应用根部（见 `main.dart` 的 `home`），监听下载任务表：
/// - 首次快照只建立基线，打开应用前就已完成的任务不追问；
/// - 只对「非 done → done」的章任务、且作品仍是非书架成员时提示；
/// - 每部作品每次会话只提示一次（批量下载逐章完成不反复打扰）；
/// - 提示是非模态 SnackBar，只有用户点「加入书架」才翻转同一条非书架行的
///   membership，绝不自动加入。
class MangaAddToShelfPromptHost extends ConsumerStatefulWidget {
  const MangaAddToShelfPromptHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<MangaAddToShelfPromptHost> createState() =>
      _MangaAddToShelfPromptHostState();
}

class _MangaAddToShelfPromptHostState
    extends ConsumerState<MangaAddToShelfPromptHost> {
  /// 最近一次任务状态快照（jobId → status），用于识别完成跃迁。
  Map<String, String> _jobStatuses = const <String, String>{};
  bool _baselineReady = false;

  /// 已经提示过的作品；批量下载只提示一次。
  final Set<String> _promptedBookKeys = <String>{};

  /// 并发刷新代号：任务表事件可能密集到达，只让最后一轮写回状态。
  int _revision = 0;

  /// 宿主挂载时刻。早于此时完成的任务属于「打开页面前就已下完」，不提示。
  final int _mountedAtMs = DateTime.now().millisecondsSinceEpoch;

  StreamSubscription<void>? _subscription;

  @override
  void initState() {
    super.initState();
    final AppModel appModel;
    try {
      appModel = ref.read(appProvider);
    } on Object {
      return;
    }
    _subscription = appModel.mangaDownloadService.watchJobs().listen(
      (_) => unawaited(_refreshJobStatuses()),
      onError: (Object error, StackTrace stack) {
        ErrorLogService.instance.log(
          'MangaAddToShelfPromptHost.watchJobs',
          error,
          stack,
        );
      },
    );
    unawaited(_refreshJobStatuses());
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  Future<void> _refreshJobStatuses() async {
    final int revision = ++_revision;
    final AppModel appModel;
    try {
      appModel = ref.read(appProvider);
    } on Object {
      return;
    }
    final List<MangaDownloadJobRow> jobs;
    try {
      jobs = await appModel.mangaDownloadService.listJobs();
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaAddToShelfPromptHost.listJobs',
        error,
        stack,
      );
      return;
    }
    if (!mounted || revision != _revision) return;

    final Map<String, String> previous = _jobStatuses;
    final Map<String, String> next = <String, String>{
      for (final MangaDownloadJobRow job in jobs) job.jobId: job.status,
    };
    _jobStatuses = next;
    if (!_baselineReady) {
      _baselineReady = true;
      return;
    }

    for (final MangaDownloadJobRow job in jobs) {
      if (job.kind != MangaDownloadJobKind.chapter) continue;
      if (job.status != MangaDownloadJobStatus.done) continue;
      if (previous[job.jobId] == MangaDownloadJobStatus.done) continue;
      // 防御：不要把挂载前就已完成的历史任务当成新完成。
      final int? completedAt = job.completedAt;
      if (completedAt != null && completedAt < _mountedAtMs) continue;
      if (!_promptedBookKeys.add(job.bookKey)) continue;

      final EpubBookRow? row = await appModel.database.getEpubBook(
        job.bookKey,
      );
      if (!mounted) return;
      if (row == null || row.isInLibrary) continue;
      _showPrompt(appModel, row);
    }
  }

  /// 非模态提示：不打断阅读，也不替用户做决定。
  void _showPrompt(AppModel appModel, EpubBookRow row) {
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    if (messenger == null) return;
    messenger.showSnackBar(
      FushiSnackBar(
        key: const ValueKey<String>('manga_series_add_to_shelf_after_download'),
        content: Text(
          t.manga_series_add_to_shelf_after_download(
            title: displayTitleForBook(
              bookKey: row.bookKey,
              rawTitle: row.title,
            ),
          ),
        ),
        duration: const Duration(seconds: 6),
        // 带 action 的 SnackBar 默认常驻；这里是「可选提示」，让它自己退场。
        persist: false,
        action: SnackBarAction(
          label: t.mihon_add_to_bookshelf,
          onPressed: () => unawaited(_addToLibrary(row.bookKey)),
        ),
      ),
    );
  }

  Future<void> _addToLibrary(String bookKey) async {
    final AppModel appModel;
    try {
      appModel = ref.read(appProvider);
    } on Object {
      return;
    }
    final EpubBookRow? current = await appModel.database.getEpubBook(bookKey);
    if (!mounted || current == null || current.isInLibrary) return;
    final OnlineMangaLibraryEntry? entry =
        OnlineMangaLibraryEntry.tryParse(current.sourceMetadata);
    if (entry == null) return;

    // 与作品页「加入书架」一致：已有 Tag 时先选择标签；取消则不加入。
    Set<int>? selectedTagIds = const <int>{};
    try {
      final List<BookTagRow> tags = await appModel.database.getAllTags();
      if (tags.isNotEmpty) {
        if (!mounted) return;
        selectedTagIds = await showTagPickerSelection(
          context,
          targets: TagTargets(
            media: <MediaRef>[
              MediaRef(kind: MediaKind.epub, entryKey: bookKey),
            ],
          ),
        );
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaAddToShelfPromptHost.loadTags',
        error,
        stack,
      );
      selectedTagIds = const <int>{};
    }
    if (selectedTagIds == null || !mounted) return;

    try {
      final OnlineMangaLibraryService service = appModel
          .onlineMangaLibraryService(entry.runtime);
      final EpubBookRow added = await service.add(entry);
      if (selectedTagIds.isNotEmpty) {
        await appModel.database.setTagsForBook(added.bookKey, selectedTagIds);
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaAddToShelfPromptHost.addToLibrary',
        error,
        stack,
      );
      if (!mounted) return;
      FushiToast.show(
        msg: describeOnlineSourceError(error),
        severity: ToastSeverity.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
