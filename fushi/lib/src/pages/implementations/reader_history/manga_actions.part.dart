part of '../reader_fushi_history_page.dart';
/// 书库行 → 在线漫画条目（只认 `format == manga` 且带章节描述符的行）。
OnlineMangaLibraryEntry? _onlineMangaEntryFromRow(EpubBookRow? row) {
  if (row == null) return null;
  if (BookFormat.parseOrEpub(row.format) != BookFormat.manga) return null;
  final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
    row.sourceMetadata,
  );
  if (entry == null || entry.chapters.isEmpty) return null;
  return entry;
}


/// Ticket 04：书架只剩漫画域。这里保留书架的多选、批量删除、拖放导入、
/// 阅读状态重置与单卡删除；听书 / 互联远端 / EPUB 书籍动作随对应域删除。

extension _MangaShelfActions<T extends HistoryReaderPage>
    on _ReaderFushiHistoryPageState<T> {
  /// 当前可见（已按标签页签筛选）的书架条目，供卡片渲染外的动作使用。
  List<MediaItem> get visibleBooks => _visibleBooksList;

  Future<void> _pullToRefreshBooks() async {
    ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    ref.invalidate(bookLastReadAtProvider);
    setState(() {
      _shelfMapsFuture = _loadShelfMaps();
    });
    await ref.read(fushiBooksProvider(JapaneseLanguage.instance).future);
  }

  Set<String> _selectableLooseKeys() => _selection.visibleLooseKeys.toSet();

  void _selectAll() {
    _rebuild(() => _selection.selectAll(
          loose: _selectableLooseKeys(),
          collections: const <int>[],
        ));
  }

  void _invertSelection() {
    _rebuild(() => _selection.invert(
          loose: _selectableLooseKeys(),
          collections: const <int>[],
        ));
  }

  Widget _buildBatchActionBar() {
    final Set<String> localKeys = _selectedLocalKeys;
    return BatchActionBar(
      selectedCount: _selectedKeys.length,
      onSelectAll: _selectAll,
      onInvertSelection: _invertSelection,
      actions: <Widget>[
        FushiIconButton(
          key: const ValueKey<String>('reader_shelf_batch_tag'),
          enabled: localKeys.isNotEmpty,
          onTap: _batchShowTagPicker,
          icon: Icons.sell_outlined,
          tooltip: t.tag_label,
        ),
        FushiIconButton(
          key: const ValueKey<String>('reader_shelf_batch_reset_progress'),
          enabled: localKeys.isNotEmpty,
          onTap: _batchResetReadingState,
          icon: Icons.restart_alt_outlined,
          tooltip: t.library_progress_reset_action,
        ),
        FushiIconButton(
          key: const ValueKey<String>('reader_shelf_batch_delete'),
          enabled: localKeys.isNotEmpty,
          onTap: _batchDeleteConfirm,
          icon: Icons.delete_outline,
          tooltip: t.dialog_delete,
          enabledColor: theme.colorScheme.error,
        ),
      ],
    );
  }

  /// 批量「重置阅读状态」：与单卡同一确认框、同一落地函数。
  Future<void> _batchResetReadingState() async {
    if (!await _pruneStaleSelection() || !mounted) return;
    final Set<String> targetKeys = _selectedLocalKeys;
    final FushiDatabase db = appModel.database;
    final List<({String bookKey, String title})> targets =
        <({String bookKey, String title})>[];
    for (final String key in targetKeys) {
      final String? bookKey = _parseBookKey(key);
      if (bookKey == null) continue;
      final EpubBookRow? row = await db.getEpubBook(bookKey);
      if (row == null) continue;
      targets.add((bookKey: bookKey, title: row.title));
    }
    if (targets.isEmpty || !mounted) return;
    final bool confirmed = await showLibraryProgressResetDialog(
      context,
      title: t.library_progress_reset_action,
      message: '${t.library_progress_reset_book_message}\n\n'
          '${t.library_progress_reset_batch_message(n: targets.length)}',
    );
    if (!confirmed || !mounted) return;
    int done = 0;
    for (final ({String bookKey, String title}) target in targets) {
      try {
        await resetBookReadingState(db: db, bookKey: target.bookKey);
        done++;
      } catch (e, stack) {
        ErrorLogService.instance
            .log('ReaderHistory.batchResetReadingState', e, stack);
      }
    }
    if (!mounted) return;
    _exitSelectionMode();
    _afterReadingStateReset();
    FushiToast.show(
      msg: done == targets.length
          ? t.library_progress_reset_batch_done(n: done)
          : t.library_progress_reset_failed,
      severity: done == targets.length
          ? ToastSeverity.success
          : ToastSeverity.warning,
    );
  }

  /// 批量移出漫画书架。目标在弹窗前定死；被当前筛选隐藏的选中项不参与本次删除。
  Future<void> _batchDeleteConfirm() async {
    if (!await _pruneStaleSelection() || !mounted) return;
    final Set<String> targetKeys = _selectedLocalKeys;
    final int mediaCount = targetKeys.length;
    if (mediaCount == 0) return;
    final int hidden = _selection.hiddenSelectedCountWhere(
      (String key) => !_isRemoteSelectionKey(key),
    );
    final String baseMessage =
        t.manga_series_remove_confirm_batch(n: mediaCount);
    final String message = hidden == 0
        ? baseMessage
        : '$baseMessage\n\n${t.batch_hidden_by_filter_note(n: hidden)}';
    final MangaLibraryRemovalDecision? decision =
        await showMangaShelfRemovalDialog(
      context,
      message: message,
      localFilesSubtitle: t.delete_local_files_download_desc,
    );
    if (decision == null || !mounted) return;

    final Set<String> toDelete = targetKeys;
    final ValueNotifier<int> progress = ValueNotifier<int>(0);
    final int total = toDelete.length;
    final NavigatorState progressNavigator =
        Navigator.of(context, rootNavigator: true);
    unawaited(
      showAppDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext ctx) => PopScope<Object?>(
          canPop: false,
          child: _ShelfBatchDeleteProgressDialog(
            progress: progress,
            total: total,
          ),
        ),
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    try {
      await _runBatchDelete(
        targetKeys: toDelete,
        decision: decision,
        progress: progress,
      );
    } finally {
      progressNavigator.pop();
    }
  }

  Future<void> _runBatchDelete({
    required Set<String> targetKeys,
    required MangaLibraryRemovalDecision decision,
    required ValueNotifier<int> progress,
  }) async {
    final bool deleteLocalFiles = decision.deleteLocalFiles;
    int succeeded = 0;
    int failed = 0;
    for (final String key in targetKeys) {
      final String? bookKey = _parseBookKey(key);
      if (bookKey == null) {
        progress.value++;
        continue;
      }
      try {
        final MangaLibraryRemovalResult result = await removeMangaFromLibrary(
          db: appModel.database,
          bookKey: bookKey,
          localSourceRoot: appModel.appPathsOrNull?.localComicRoot,
          downloadsRoot: appModel.appPathsOrNull?.downloadsRoot,
          deleteLocalFiles: deleteLocalFiles,
          downloadService: appModel.mangaDownloadService,
        );
        if (result.removed) {
          succeeded++;
        } else {
          failed++;
          ErrorLogService.instance.log(
            'ReaderHistory.batchRemoveFromLibrary',
            '${result.failure?.name ?? 'remove failed'}'
            '${result.detail == null ? '' : ': ${result.detail}'}',
          );
        }
      } on Object catch (error, stack) {
        failed++;
        ErrorLogService.instance.log(
          'ReaderHistory.batchRemoveFromLibrary',
          error,
          stack,
        );
      }
      progress.value++;
    }
    if (!mounted) return;
    _refreshShelfAfterMutation();
    _exitSelectionMode();
    FushiToast.show(
      msg: t.local_source_batch_remove_done(
        success: succeeded,
        failed: failed,
      ),
      severity: failed == 0 ? ToastSeverity.success : ToastSeverity.warning,
    );
  }

  /// 批量操作前把选中集收敛到仍在书架上的条目。
  Future<bool> _pruneStaleSelection() async {
    if (_selection.isEmpty) return false;
    final FushiDatabase db = appModel.database;
    final List<EpubBookMeta> epubBooks = await db.getEpubBookMetas();
    _epubUidByKey = <String, String>{
      for (final EpubBookMeta row in epubBooks)
        if (row.uid.isNotEmpty) row.bookKey: row.uid,
    };
    if (!mounted) return false;
    final int dropped = _selection.retainExisting(
      loose: <String>{
        for (final EpubBookMeta row in epubBooks)
          if (row.isInLibrary)
            ReaderFushiSource.mediaIdentifierFor(row.bookKey),
      },
      collections: const <int>{},
    );
    if (dropped == 0) return _selection.isNotEmpty;
    _rebuild(() {});
    FushiToast.show(
      msg: t.batch_selection_stale_skipped(
        n: dropped + _selection.length,
        m: dropped,
      ),
      severity: ToastSeverity.warning,
    );
    return _selection.isNotEmpty;
  }

  Future<void> _batchShowTagPicker() async {
    if (!await _pruneStaleSelection() || !mounted) return;
    final List<MediaRef> media = <MediaRef>[
      for (final String key in _selectedLocalKeys)
        if (_parseBookKey(key) case final String bookKey)
          MediaRef(kind: MediaKind.epub, entryKey: bookKey),
    ];
    final TagTargets targets = TagTargets(media: media);
    if (targets.isEmpty) return;
    await showTagPicker(context, targets: targets);
    if (!mounted) return;
    ref.invalidate(allTagsProvider);
    ref.invalidate(bookTagMapProvider);
    ref.invalidate(filteredBookIdsProvider);
  }

  /// 单卡「移出书架」：与作品页 / 批量删除共用统一弹窗。
  Future<void> _confirmMangaShelfDelete(String bookKey) async {
    Navigator.pop(context);
    final MangaLibraryRemovalDecision? decision =
        await showMangaShelfRemovalDialog(
      context,
      message: t.manga_series_remove_confirm,
      localFilesSubtitle: t.delete_local_files_download_desc,
    );
    if (decision == null || !mounted) return;
    final MangaLibraryRemovalResult result = await removeMangaFromLibrary(
      db: appModel.database,
      bookKey: bookKey,
      localSourceRoot: appModel.appPathsOrNull?.localComicRoot,
      downloadsRoot: appModel.appPathsOrNull?.downloadsRoot,
      deleteLocalFiles: decision.deleteLocalFiles,
      downloadService: appModel.mangaDownloadService,
    );
    if (!mounted) return;
    if (!result.removed) {
      FushiToast.show(
        msg: result.failureMessage,
        severity: ToastSeverity.error,
      );
      return;
    }
    _refreshShelfAfterMutation();
  }

  /// 单卡重置阅读状态（进度归零 + 取消读完 + 离开继续阅读）。
  Future<void> _resetBookReadingState(String bookKey) async {
    Navigator.pop(context);
    final bool confirmed = await showLibraryProgressResetDialog(
      context,
      title: t.library_progress_reset_action,
      message: t.library_progress_reset_book_message,
    );
    if (!confirmed || !mounted) return;
    await resetBookReadingState(db: appModel.database, bookKey: bookKey);
    _afterReadingStateReset();
  }

  void _afterReadingStateReset() {
    if (!mounted) return;
    ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    ref.invalidate(bookLastReadAtProvider);
    ref.invalidate(completedEpubBookKeysProvider);
    setState(() {
      _shelfMapsFuture = _loadShelfMaps();
    });
  }

  void _refreshShelfAfterMutation() {
    ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    ref.invalidate(bookTagMapProvider);
    ref.invalidate(allTagsProvider);
    setState(() {
      _shelfMapsFuture = _loadShelfMaps();
    });
  }

  /// 书架拖放：只保留漫画导入与本地图源目录登记。
  Future<void> _handleShelfDrop(
    List<String> paths,
    Offset globalPosition,
  ) async {
    final Map<String, bool> imageArchives =
        await probeDroppedImageArchives(paths, preferManga: true);
    if (!mounted) return;
    final DroppedFiles files = classifyDroppedFiles(
      paths,
      isDirectory: (String path) => Directory(path).existsSync(),
      isImageArchive: (String path) => imageArchives[path] ?? false,
      preferManga: true,
    );
    final DropIntent intent = decideDropIntent(
      surface: DropSurface.manga,
      files: files,
      cardHit: false,
    );
    switch (intent) {
      case DropIntent.importNewManga:
        if (!_moduleVisibility.isEnabled(ModuleId.manga)) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              FushiSnackBar(content: Text(t.module_disabled_hint)),
            );
          }
          return;
        }
        _openMangaImportPrefilled(mangaPaths: files.mangas);
      case DropIntent.unsupportedMangaArchive:
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            FushiSnackBar(content: Text(t.drag_drop_manga_archive_unsupported)),
          );
        }
      default:
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            FushiSnackBar(content: Text(t.drag_drop_unsupported_on_books)),
          );
        }
    }
  }

  /// 拖入漫画 → 打开 [MangaImportDialog]，页图文件夹走 Local source 登记。
  Future<void> _openMangaImportPrefilled({
    required List<String> mangaPaths,
  }) async {
    final List<String> localFolders = <String>[];
    final List<String> dialogPaths = <String>[];
    for (final String path in mangaPaths) {
      final bool localSourceFolder = Directory(path).existsSync() &&
          MangaModule.directoryHasPageImages(path) &&
          MangaModule.directoryMokuroFileCount(path) == 0;
      (localSourceFolder ? localFolders : dialogPaths).add(path);
    }

    if (localFolders.isNotEmpty) {
      int imported = 0;
      int skipped = 0;
      int failed = 0;
      for (final String path in localFolders) {
        try {
          final LocalSourceDropResult result =
              await LocalSourceDrop.importDroppedPath(
            db: appModel.database,
            root: appModel.appPaths.localComicRoot,
            sourcePath: path,
          );
          final LocalSourceRegistrationReport? report = result.report;
          if (report != null) {
            imported += report.added + report.refreshed;
            skipped += report.skippedTombstoned;
            failed += report.failed;
          }
          if (!result.registered) failed++;
        } on Object catch (error, stack) {
          failed++;
          ErrorLogService.instance.log(
            'ReaderFushiHistoryPage.localSourceDrop',
            error,
            stack,
          );
        }
      }
      if (mounted) {
        FushiToast.show(
          msg: t.manga_import_batch_done(
            imported: imported,
            skipped: skipped,
            failed: failed,
          ),
          severity:
              imported > 0 ? ToastSeverity.success : ToastSeverity.error,
        );
      }
    }

    if (dialogPaths.isEmpty) {
      if (mounted && localFolders.isNotEmpty) {
        _refreshShelfAfterMutation();
      }
      return;
    }
    if (!mounted) return;

    final bool? imported = await showAppDialog<bool>(
      context: context,
      builder: (_) => MangaImportDialog(
        db: appModel.database,
        initialPaths: dialogPaths,
      ),
    );
    if ((imported == true || localFolders.isNotEmpty) && mounted) {
      _refreshShelfAfterMutation();
    }
  }
}

/// 书架批量删除的阻塞式进度弹窗（manga-only 版）。
class _ShelfBatchDeleteProgressDialog extends StatelessWidget {
  const _ShelfBatchDeleteProgressDialog({
    required this.progress,
    required this.total,
  });

  final ValueNotifier<int> progress;
  final int total;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      maxWidth: 360,
      scrollable: false,
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.card),
        child: ValueListenableBuilder<int>(
          valueListenable: progress,
          builder: (BuildContext context, int done, Widget? _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${t.delete_in_progress} $done / $total',
                  style: tokens.type.listTitle,
                ),
                SizedBox(height: tokens.spacing.gap),
                FushiLinearProgressIndicator(
                  value: total == 0 ? null : done / total,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
