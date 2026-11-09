// GENERATED-NOTE: extracted from reader_fushi_history_page.dart (TODO-587).
part of '../reader_fushi_history_page.dart';

/// TODO-919 / BUG-441：判定一条 [SrtBook] 是否为「EPUB 有声书配对行」。
///
/// TODO-894 起，EPUB 有声书导入会额外落一条 `srt_books` 行（stable uid
/// `srtbook_epub_<bookKey>`）以打通同步导出。该行 [SrtBook.bookKey] 非空
/// 且携带音频（[SrtBook.audioPaths] 非空或 [SrtBook.audioRoot] 非空）。书架对
/// 这种行渲染时应保留有声书语义的耳机角标（与 `_audiobookBadge` 一致），而不是
/// 纯字幕书的字幕角标。纯字幕书（无 EPUB 关联，[SrtBook.bookKey] 为空）仍用字幕
/// 角标——消除特殊情况只在这一处判据。
/// P4：SRT/有声书卡上屏名统一入口——过 display-title 门面应用编辑弹窗写入的
/// override。门面按身份分派：bookKey 非空走 EPUB 共享身份 `hoshi://book/<key>`，
/// 空串哨兵（standalone SRT）走 `hoshi://srtbook/<uid>`（BUG-1018 A3，与
/// `_srtBookMediaItem` 同一套分派）。
String _srtDisplayTitle(SrtBook book) => displayTitleForBook(
      bookKey: book.bookKey,
      srtUid: book.uid,
      rawTitle: book.title,
    );

bool isEpubBackedAudiobookSrt(SrtBook book) {
  if (book.bookKey.isEmpty) return false;
  final List<String>? audioPaths = book.audioPaths;
  final bool hasAudioPaths = audioPaths != null && audioPaths.isNotEmpty;
  final String? audioRoot = book.audioRoot;
  final bool hasAudioRoot = audioRoot != null && audioRoot.isNotEmpty;
  return hasAudioPaths || hasAudioRoot;
}

/// 本地 [EpubBookRow] 是否为可批量下载的在线漫画：漫画格式 + `sourceMetadata`
/// 能解析出带章节列表的在线漫画描述符。本地卷（没有描述符）返回 null。
///
/// 判据与作品页「下载全部」同源（`OnlineMangaLibraryEntry.tryParse`），不新增
/// 身份字段；`chapters.isEmpty` 的条目没有可下载的章，按本地卷处理。
OnlineMangaLibraryEntry? _onlineMangaEntryFromRow(EpubBookRow? row) {
  if (row == null) return null;
  if (BookFormat.parseOrEpub(row.format) != BookFormat.manga) return null;
  final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
    row.sourceMetadata,
  );
  if (entry == null || entry.chapters.isEmpty) return null;
  return entry;
}

/// 可经批量下载搬走的远端漫画：`format == 'manga'`，且有章节（在线条目，走收养
/// + 逐章入队）或有整本包内容（`hasContent`，走整本文件下载链）。纯 SRT 有声书、
/// EPUB / PDF 等非漫画远端条目一律不算——批量下载只服务在线漫画（ticket 02 复审 B）。
bool _isDownloadableRemoteManga(RemoteBookInfo book) =>
    BookFormat.parseOrEpub(book.format) == BookFormat.manga &&
    (book.hasMangaChapters || book.hasContent);

/// 选中集里的本地键 → 在线漫画条目（批量下载按钮可用态的唯一数据源）。
final _shelfOnlineMangaEntryProvider =
    FutureProvider.family<OnlineMangaLibraryEntry?, String>(
  (ref, bookKey) async {
    final FushiDatabase db = ref.watch(appProvider).database;
    return _onlineMangaEntryFromRow(await db.getEpubBook(bookKey));
  },
);

/// books domain methods extracted via part-of (TODO-587); shared private scope.
extension _ReaderHistoryBooks on _ReaderFushiHistoryPageState {
  // v79：srtBookTagMapProvider 键换 uid（String）。泛型 map 索引不受编译器
  // 保护——int 键查 String 键 map 恒 miss 且 analyze 全绿（review5-3），
  // 类型签名钉死在 String 上防复发。
  Widget? _buildSrtBookTagLabels(String srtUid) => _tagLabelsFromMap(
        ref.watch(srtBookTagMapProvider).valueOrNull,
        srtUid,
      );

  /// [selectable]（默认 true）= 多选态可单独勾选。
  /// [focusIdPrefix]：详情页渲染路径传 'collection-detail-' 隔离焦点 id 命名空间；
  /// 书架路径恒空串（id 不变）。
  Widget _buildSrtCard(SrtBook book,
      {String? epubCoverUri,
      bool selectable = true,
      String focusIdPrefix = ''}) {
    final String selKey = 'srt_${book.uid}';
    final tagWidget = _buildSrtBookTagLabels(book.uid);
    final int? srtBookId = book.id;
    // TODO-919 / BUG-441：EPUB 有声书配对行（TODO-894 落的 srt_books）保留耳机角标，
    // 纯字幕书仍用字幕角标。
    // TODO-935 ①A：引用导入后原音频断链 → 角标改成错误态「文件丢失」提示。
    final bool audioMissing = _srtBookHasMissingAudio(book);
    final IconData badgeIcon = audioMissing
        ? Icons.error_outline
        : isEpubBackedAudiobookSrt(book)
            ? Icons.headphones_outlined
            : Icons.subtitles_outlined;
    // TODO-1094：书架 SRT 卡书名必须与长按对话框同源——两者都基于同一
    // [_srtBookMediaItem]，再经 [MediaSource.getDisplayTitleFromMediaItem] 应用
    // 编辑弹窗写入的 override_title 偏好。以前直接读 DB 原始列 book.title，忽略
    // override，导致「编辑书名」保存后网格仍显示旧名。
    final MediaItem srtItem = _srtBookMediaItem(book);
    final String displayTitle =
        mediaSource.getDisplayTitleFromMediaItem(srtItem);
    return _bookCardShell(
      slotAspectRatio: kShelfBookCardAspectRatio,
      cardKey: ValueKey<String>('srt_entry_${book.uid}'),
      focusId: FushiFocusId('${focusIdPrefix}reader-shelf-srt-${book.uid}'),
      selectionKey: selectable ? selKey : null,
      dragBookId: srtBookId,
      onTagDropped: (tag) => _addTagToSrtBook(book.uid, tag),
      // 拖卡进合集：SRT 的合集身份是 **uid**，不是上面打标签用的 int 主键
      // `srtBookId`（`_addSrtToCollection` 同源）——两者不可混用。
      dragMediaRef: MediaRef(kind: MediaKind.srt, entryKey: book.uid),
      dragLabel: displayTitle,
      onTap: () => _openSrtBook(book),
      onLongPress: () => _showSrtBookDialog(book),
      child: _bookCardLayout(
        title: displayTitle,
        cover: _buildSrtCover(book, epubCoverUri: epubCoverUri),
        tagLabels: tagWidget,
        coverBadge: _cardBadge(
          icon: badgeIcon,
          tooltip: audioMissing ? t.audiobook_audio_missing : null,
          background: audioMissing
              ? theme.colorScheme.errorContainer
              : theme.colorScheme.secondaryContainer,
          foreground: audioMissing
              ? theme.colorScheme.onErrorContainer
              : theme.colorScheme.onSecondaryContainer,
        ),
        // BUG-728：EPUB-backed 有声书只以 SRT 卡出现，进度条走与 EPUB 卡同一个
        // [_progressBar]（读 srtItem.position/duration，来自共享 EpubBooks 行）。
        // 纯字幕书无进度真值则不传 metadata，保持原样（无进度条）。已手动标记读完的
        // 有声书（按配对 bookKey 命中 [_completedBookKeys]）进度条恒满格 + 区分色。
        metadata: _srtBookHasProgress(book)
            ? _progressBar(
                srtItem,
                completed: book.bookKey.isNotEmpty &&
                    _completedBookKeys.contains(book.bookKey),
              )
            : null,
        // BUG-990：两阶段下载末段卡已变 SRT 卡但有声书包仍在下 → 继续显示加载覆盖层。
        loadingOverlay: _audiobookDownloadingOverlay(book.bookKey),
      ),
    );
  }

  Widget _buildSrtCover(SrtBook book, {String? epubCoverUri}) {
    // TODO-919 / BUG-441：占位/封面 fallback 图标随卡片类型走——EPUB 有声书配对行
    // 用耳机，纯字幕书用字幕，与角标保持同一判据。
    final IconData fallbackIcon = isEpubBackedAudiobookSrt(book)
        ? Icons.headphones_outlined
        : Icons.subtitles_outlined;
    // TODO-1191：SRT 卡封面优先用「编辑信息」弹窗写入的 override thumbnail（经
    // [MediaSource.setOverrideThumbnailFromMediaItem]，与 EPUB 等其它书卡同源）。
    // 以前 SRT 卡只读 book.coverPath（旧外层「选择封面图片」专有写入），忽略
    // override，导致在编辑信息弹窗里选的封面在网格卡上不生效。现在统一到 override，
    // 无 override 再退回 book.coverPath（向后兼容历史外层写入的封面）与关联 EPUB 封面。
    // BUG-1317：读 override 封面必须走 resolveOverrideThumbnailFile——它才认得
    // 存量的旧文件名（源键烧进 hash）并就地迁移；裸 getOverrideThumbnailFilename
    // 只拿得到规范路径，会把还没迁移的封面判成「没有」。
    final File? overrideCover =
        ReaderFushiSource.instance.resolveOverrideThumbnailFile(
      appModel: appModel,
      item: _srtBookMediaItem(book),
    );
    if (overrideCover != null) {
      return _buildFileCover(overrideCover.path, fallbackIcon);
    }
    final String? ownCoverPath = _existingCoverFilePath(book.coverPath);
    if (ownCoverPath != null) {
      return _buildFileCover(ownCoverPath, fallbackIcon);
    }
    if (book.bookKey.isNotEmpty) {
      final Widget? linkedCover = _buildCoverFromUri(
        epubCoverUri,
        fallbackIcon,
      );
      if (linkedCover != null) return linkedCover;
    }
    return _coverPlaceholderIcon(fallbackIcon);
  }

  MediaItem _srtBookMediaItem(SrtBook book) {
    final String? ownCoverPath = _existingCoverFilePath(book.coverPath);
    final String? imageUrl = ownCoverPath != null
        ? Uri.file(ownCoverPath).toString()
        : _epubCoverUrisByBookKey[book.bookKey];
    // BUG-728：EPUB-backed 有声书在书架只以 SRT 卡出现（其 EPUB 卡被过滤），进度
    // 复用同一本 EpubBooks 行已算好的 position/duration（含听书 normCharOffset 回退）。
    // 无 EPUB backing 的纯字幕书没有字符进度真值，退回 0/1（进度条按 [_srtBookHasProgress]
    // 门控不渲染，不灌水）。
    final ({int position, int duration})? prog =
        _epubProgressByBookKey[book.bookKey];
    return MediaItem(
      // BUG-1018 (A3)：standalone SRT 书（bookKey 空串哨兵）用自己的稳定身份
      // `hoshi://srtbook/<uid>`——以前所有 standalone SRT 书共享
      // mediaIdentifierFor('')，override 书名/封面互相踩、作者保存静默 no-op。
      // EPUB 配对行照旧走 bookKey 身份（与 EPUB 卡同源，进度/override 共享）。
      mediaIdentifier: book.bookKey.isNotEmpty
          ? ReaderFushiSource.mediaIdentifierFor(book.bookKey)
          : ReaderFushiSource.mediaIdentifierForSrtUid(book.uid),
      title: book.title,
      // BUG-1018 (A3)：standalone SRT 书作者列真值在 srt_books.author，回填供
      // 编辑对话框预填/保存往返。EPUB 配对行作者真值在 epubBooks.author（编辑
      // 保存按 bookKey 写穿），此处不冒充。
      author: book.bookKey.isEmpty ? book.author : null,
      mediaTypeIdentifier: ReaderFushiSource.instance.mediaType.uniqueKey,
      mediaSourceIdentifier: ReaderFushiSource.instance.uniqueKey,
      position: prog?.position ?? 0,
      duration: prog?.duration ?? 1,
      canDelete: false,
      canEdit: true,
      imageUrl: imageUrl,
    );
  }

  /// BUG-728：SRT 卡是否有可展示的阅读进度真值。仅 EPUB-backed 有声书（其 bookKey
  /// 命中 [_epubProgressByBookKey]，进度来自共享的 EpubBooks 行 + reader_positions）
  /// 才画进度条；纯字幕书无字符进度，返回 false，保持无进度条（不显永远空的条）。
  bool _srtBookHasProgress(SrtBook book) =>
      book.bookKey.isNotEmpty &&
      _epubProgressByBookKey.containsKey(book.bookKey);

  Future<void> _openSrtBook(SrtBook book) async {
    if (book.bookKey.isEmpty) {
      FushiToast.show(msg: t.srt_epub_not_ready, severity: ToastSeverity.error);
      return;
    }
    // BUG-456: SRT books must use the normal media entry so AppModel registers
    // ReaderFushiSource; direct page pushes leave currentMediaSource null.
    await appModel.openMedia(
      ref: ref,
      mediaSource: ReaderFushiSource.instance,
      item: _srtBookMediaItem(book),
    );
  }

  List<DialogAction> _srtExtraActions(BuildContext dialogContext, SrtBook book) {
    final String bookKey = book.bookKey;
    final MediaItem item = _srtBookMediaItem(book);
    // 与 EPUB 卡菜单同款：一次快照，逐条按模块过滤通往别的模块的项。
    final ModuleVisibility modules = _moduleVisibility;
    return [
      DialogDangerAction(
        label: t.dialog_delete,
        onPressed: () async {
          Navigator.pop(dialogContext);
          await _confirmDeleteSrtBook(book);
        },
      ),
      // 2026-10 体验优化：「音频文件丢失」此前只在角标 Tooltip 里（触屏看不到），
      // 菜单里只有一颗不说原因的「重新定位文件」快捷键。改为列表首项，文案把
      // 原因和动作一起说出来。
      if (_srtBookHasMissingAudio(book) &&
          modules.isEnabled(ModuleId.listening))
        DialogListAction(
          label: '${t.audiobook_audio_missing} · ${t.audiobook_relocate}',
          icon: Icons.find_replace_outlined,
          onPressed: () async {
            Navigator.pop(dialogContext);
            await _relocateSrtBookAudio(book);
          },
        ),
      // 纯字幕（standalone）有声书的「从互联对端重新拉取」：host 上重新转录 / 换了
      // 字幕之后把新字幕（或整本）拉回来。与 EPUB 书卡的同名两项同一语义、同一套
      // 拉取与导入（只更新字幕不动音频，本机进度 / 断点 / 调轴保留）；配对书
      // （bookKey 非空）的入口在 EPUB 书卡上，这里不重复给。
      if (bookKey.isEmpty &&
          modules.isEnabled(ModuleId.listening) &&
          _remoteSrtRefetchFor(book.uid) != null) ...<DialogAction>[
        DialogListAction(
          label: t.remote_book_subtitles_refresh,
          icon: FushiIcons.subtitles,
          onPressed: () async {
            final RemoteAudiobookInfo remote = _remoteSrtRefetchFor(book.uid)!;
            Navigator.pop(dialogContext);
            await _refetchRemoteSrtAudiobook(remote, subtitlesOnly: true);
          },
        ),
        DialogListAction(
          label: t.remote_book_audiobook_redownload,
          icon: FushiIcons.cloudSync,
          onPressed: () async {
            final RemoteAudiobookInfo remote = _remoteSrtRefetchFor(book.uid)!;
            Navigator.pop(dialogContext);
            await _refetchRemoteSrtAudiobook(remote, subtitlesOnly: false);
          },
        ),
      ],
      // 三库页对称：与 EPUB / 视频 / 游戏卡一样，「重命名」排在列表项首位。落的是
      // 显示名覆盖层，SrtBooks.title 不动（同 bookKey 换身份的理由）。
      DialogListAction(
        label: t.book_rename,
        icon: Icons.drive_file_rename_outline,
        onPressed: () => _renameBook(dialogContext, item),
      ),
      // 统一三库页卡菜单：SRT 卡与 EPUB/视频/游戏卡对称含「标签」项（用户
      // 2026-07-28 拍板推翻 TODO-455；内部自行收起本对话框）。身份 =
      // SrtBooks.uid（与合集/批量选择键解码一致）。
      DialogListAction(
        label: t.tag_label,
        icon: Icons.sell_outlined,
        onPressed: () => _openMediaTagPicker(
          MediaRef(kind: MediaKind.srt, entryKey: book.uid),
        ),
      ),
      // 「重新导入」：音频 + 字幕两半一起换。旧入口叫「导入音频」且只能换音频，
      // 字幕书的字幕在首次导入后全仓无处可换（用户报「有声书没办法重新导入 /
      // 导不了字幕文件」）。对 bookKey 为空的孤儿字幕书同样可见——它们才是最需要
      // 换字幕的一类（首次导入 cue 解析失败才会落成孤儿）。
      if (modules.isEnabled(ModuleId.listening))
        DialogQuickAction(
          label: t.srt_book_reimport,
          icon: Icons.headphones_outlined,
          onPressed: () async {
            Navigator.pop(dialogContext);
            await _openSrtBookReimport(book);
          },
        ),
      if (bookKey.isNotEmpty) ...[
        // 与 EPUB 卡菜单对称：手动「标记为已读完 / 取消」。有声书完成状态与 EPUB 共用
        // 同一 EpubBooks.completedAt（按配对 bookKey），故复用同一 [_toggleBookCompleted]。
        DialogListAction(
          label: _completedBookKeys.contains(bookKey)
              ? t.book_mark_uncompleted_action
              : t.book_mark_completed_action,
          icon: _completedBookKeys.contains(bookKey)
              ? Icons.check_circle
              : Icons.check_circle_outline,
          onPressed: () => _toggleBookCompleted(bookKey),
        ),
        // 与 EPUB 卡菜单对称：「重置阅读状态」。后台听书时钟对配对字幕书也可能按
        // SRT uid 记账，所以统计身份带上 uid。
        DialogListAction(
          label: t.library_progress_reset_action,
          icon: Icons.restart_alt_outlined,
          onPressed: () =>
              _resetBookReadingState(item, bookKey, srtUid: book.uid),
        ),
        // TODO-1068：SRT/有声书卡长按菜单对称补「悬浮字幕」项（与 EPUB 侧
        // extraActions 一致）。复用同一 i18n key、同一回调、同一平台门控；
        // bookKey 非空才可用，_toggleFloatingLyricFromShelf 按 bookKey 解析。
        if ((Platform.isAndroid || Platform.isWindows) &&
            modules.isEnabled(ModuleId.listening))
          // 2026-10 体验优化：开启态不再拼「悬浮字幕 ✓」（看不出点了是开还是关），
          // 改成明确的「关闭悬浮字幕」+ 不同图标。
          DialogListAction(
            label: _isBackgroundListeningBook(bookKey)
                ? t.floating_lyric_stop_action
                : t.floating_lyric_toggle_action,
            icon: _isBackgroundListeningBook(bookKey)
                ? Icons.subtitles_off_outlined
                : Icons.subtitles_outlined,
            onPressed: () => _toggleFloatingLyricFromShelf(bookKey),
          ),
      ],
    ];
  }

  Future<void> _showSrtBookDialog(SrtBook book) async {
    await showAppDialog(
      context: context,
      builder: (ctx) => MediaItemDialogPage(
        item: _srtBookMediaItem(book),
        isHistory: true,
        showLaunchAction: false,
        // TODO-1094：SRT 无自选封面且未关联 EPUB 封面时，长按对话框显示与网格
        // `_buildSrtCover` 同判据的占位图标（耳机/字幕），而非整块隐藏封面区。
        coverFallbackIcon: isEpubBackedAudiobookSrt(book)
            ? Icons.headphones_outlined
            : Icons.subtitles_outlined,
        extraActions: (_) => _srtExtraActions(ctx, book),
      ),
    );
    if (mounted) _rebuild(() {});
  }

  /// TODO-935 ①A：字幕书引用导入后原音频被移动/删除 → 任一 audioPaths 断链。
  /// 仅对 files 模式（audioPaths）判定；folder 模式（audioRoot）不在本期范围。
  bool _srtBookHasMissingAudio(SrtBook book) {
    final List<String>? paths = book.audioPaths;
    if (paths == null || paths.isEmpty) return false;
    return AudiobookStorage.hasMissingPaths(paths);
  }

  /// 重新定位断链音频：让用户重选文件 → 重写 [SrtBook.audioPaths] → 落库。
  /// 复用与导入一致的「引用原路径」语义（重选的桌面真实路径直接存）。
  Future<void> _relocateSrtBookAudio(SrtBook book) async {
    final List<String> picked = await _pickSrtAudioFiles();
    if (picked.isEmpty || !mounted) return;
    book.audioPaths = picked;
    await SrtBookRepository(appModel.database).save(book);
    if (mounted) {
      _refreshSrtBooks();
      _rebuild(() {});
      FushiToast.show(
          msg: t.audiobook_relocate_done, severity: ToastSeverity.success);
    }
  }

  /// 全选 / 反选的候选散卡键 = **屏幕上真的画出来的那些散卡**，直接取每帧
  /// [MediaSelectionController.setVisibleOrder] 登记的可见散卡序（那份就是按
  /// `groupByCollections` 折叠后剩下的散卡组逐项推出来的）。
  ///
  /// 此前这里自推一遍资格（`!_isEpubCollectionMember` / `!_isSrtCollectionMember`，
  /// 两个方法已随之删除，免得又被当成判据捡回来），与登记可见序的那份口径是两处
  /// 推导、已经漂开了：`collectionIdOf` 要求合集**当前还存在**才算折叠，那两个
  /// 方法却只查归属键在不在。于是合集行被删、成员行还在的孤儿条目在墙上按散卡
  /// 渲染、进得了可见序，却被判成合集成员排除出候选——单击能勾、全选勾不上、
  /// 反选也还不掉。视频库同一处已收敛到真相源，这里跟上。
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
    // BUG-2458：散卡选中集里混着远端占位键——「已选 N」计全部，但打标签 /
    // 删除两个本地动作只按本地键判可用态与取目标；远端键只喂「下载」，且只有
    // 可下载漫画（format=manga + 章节 / 整本包）才点亮该动作（ticket 02 复审 B）。
    // 2026-11-05：合集已删除，选中集只剩散卡。
    // 2026-11-06（ticket 02）：下载只服务在线漫画——本地卷没有可下载的章节，
    // 只选中它们时禁用；本地在线漫画条目（带章节列表的在线描述符）同样启用。
    final Set<String> localKeys = _selectedLocalKeys;
    final Set<String> remoteKeys = _selectedRemoteKeys;
    final List<String> localBookKeys = <String>[
      for (final String key in localKeys)
        if (!key.startsWith('srt_'))
          if (_parseBookKey(key) case final String bookKey) bookKey,
    ];
    final bool hasOnlineLocalManga = localBookKeys
        .map(
          (String bookKey) =>
              ref.watch(_shelfOnlineMangaEntryProvider(bookKey)).valueOrNull,
        )
        .any((OnlineMangaLibraryEntry? entry) => entry != null);
    // 远端选中项里只有可下载漫画算数：纯 SRT 有声书与非漫画远端书都不启用下载。
    final _RemoteBookState? remoteState = _lastRemoteState;
    final bool hasDownloadableRemoteManga = remoteState != null &&
        remoteState.books.any(
          (RemoteBookInfo book) =>
              remoteKeys.contains(_remoteBookSelectionKey(book)) &&
              _isDownloadableRemoteManga(book),
        );
    return BatchActionBar(
      selectedCount: _selectedKeys.length,
      onSelectAll: _selectAll,
      onInvertSelection: _invertSelection,
      actions: <Widget>[
        FushiIconButton(
          key: const ValueKey<String>('reader_shelf_batch_download'),
          enabled: hasDownloadableRemoteManga || hasOnlineLocalManga,
          onTap: _batchDownloadSelected,
          icon: Icons.download_outlined,
          tooltip: t.remote_book_download,
        ),
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

  /// 批量「重置阅读状态」：与单卡同一确认框、同一落地函数 [resetBookReadingState]。
  /// 目标在弹窗前定死（与 [_batchDeleteConfirm] 同纪律）；纯字幕书（bookKey 空）没有
  /// 进度 / 读完真值载体，跳过且不计数。
  Future<void> _batchResetReadingState() async {
    if (!await _pruneStaleSelection() || !mounted) return;
    final Set<String> targetKeys = _selectedLocalKeys;
    final FushiDatabase db = appModel.database;
    final SrtBookRepository srtRepo = SrtBookRepository(db);
    final List<({String bookKey, String? srtUid, String title})> targets =
        <({String bookKey, String? srtUid, String title})>[];
    for (final String key in targetKeys) {
      if (key.startsWith('srt_')) {
        final SrtBook? book = await srtRepo.findByUid(key.substring(4));
        if (book != null && book.bookKey.isNotEmpty) {
          targets.add(
            (bookKey: book.bookKey, srtUid: book.uid, title: book.title),
          );
        }
        continue;
      }
      final String? bookKey = _parseBookKey(key);
      if (bookKey == null) continue;
      final EpubBookRow? row = await db.getEpubBook(bookKey);
      if (row == null) continue;
      targets.add((bookKey: bookKey, srtUid: null, title: row.title));
    }
    if (targets.isEmpty || !mounted) return;
    final StudyRecordResetScope? records = await showLibraryProgressResetDialog(
      context,
      title: t.library_progress_reset_action,
      message: '${t.library_progress_reset_book_message}\n\n'
          '${t.library_progress_reset_batch_message(n: targets.length)}',
    );
    if (records == null || !mounted) return;
    int done = 0;
    for (final ({String bookKey, String? srtUid, String title}) target
        in targets) {
      try {
        await resetBookReadingState(
          db: db,
          bookKey: target.bookKey,
          title: target.title,
          extraStatKeys: <String>{
            if (target.srtUid != null) target.srtUid!,
          },
          records: records,
        );
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

  /// 批量移出漫画书架（选中散卡里的 EPUB / 漫画 / SRT）。
  ///
  /// 票 02：与作品页共用票 01 的统一弹窗（标题、说明、两个默认不勾选的选项），
  /// 不再有粉/蓝披露块、「记住这些选择」与同步范围。目标在弹窗前定死；被当前
  /// 搜索 / 标签筛选隐藏的选中项继续提示，且不参与本次删除。
  Future<void> _batchDeleteConfirm() async {
    // 先剔幽灵键再取数：确认框里的 N 必须是真会被删的条数。
    if (!await _pruneStaleSelection() || !mounted) return;
    // **在弹确认框之前就把目标定死**：选中集是只暴露当前可见项的派生视图，弹窗
    // 期间任何一次改变可见序的重建（筛选 provider 解析完成、书架刷新）都会让它
    // 自己变，跨 await 两侧各读一次会让确认框的数字与实际删除量对不上。
    final Set<String> targetKeys = _selectedLocalKeys;
    final int mediaCount = targetKeys.length;
    if (mediaCount == 0) return;
    final String baseMessage =
        t.manga_series_remove_confirm_batch(n: mediaCount);
    // 勾过但被当前搜索/标签筛选挡住的那些不会被删，必须说出来。
    // 只数本地键：远端占位键不是删除对象（BUG-2458 审查 #4）。
    final int hidden = _selection.hiddenSelectedCountWhere(
      (String key) => !_isRemoteSelectionKey(key),
    );
    final String message = hidden == 0
        ? baseMessage
        : '$baseMessage\n\n${t.batch_hidden_by_filter_note(n: hidden)}';
    final MangaLibraryRemovalDecision? decision =
        await showMangaShelfRemovalDialog(
      context,
      message: message,
      localFilesSubtitle: t.delete_local_files_download_desc,
      statisticsSubtitle: t.delete_statistics_manga_batch_desc,
    );
    if (decision == null || !mounted) return;

    // 2026-10 体验优化：确认后进入忙碌态——阻塞式进度弹窗（不可点遮罩 / 返回
    // 关闭），批量栏与卡片在删除期间都点不到。此前确认框一关页面毫无反馈，
    // 几十本书要删好几秒，用户以为没生效又点一次，或在删除途中改选中集。
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
    // 等进度弹窗真正挂上再开删：删除若瞬间完成，下面的 pop 不能先于 push。
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

  /// [_batchDeleteConfirm] 确认后的执行体（2026-10 体验优化拆出，外层负责忙碌态）。
  ///
  /// 票 02：逐作品独立处理——每部先停在线下载任务，再按作品来源删文件（在线已下载
  /// 章节 / Local source 原作），成功后才删数据库；失败的作品留在 Library。成功与
  /// 失败分别计数并如实报告。每处理完一张卡把 [progress] +1。
  Future<void> _runBatchDelete({
    required Set<String> targetKeys,
    required MangaLibraryRemovalDecision decision,
    required ValueNotifier<int> progress,
  }) async {
    final bool deleteLocalFiles = decision.deleteLocalFiles;
    final bool deleteStatistics = decision.deleteStatistics;

    int succeeded = 0;
    int failed = 0;
    // 目标集在确认框弹出前就定死（[targetKeys]），不重新读 `_selectedKeys`。
    final Set<String> toDelete = targetKeys;
    // my-comic 的漫画-only live schema（37 表）没有 srt_books：表不存在时选中集
    // 里不可能有本地字幕卡（卡片本就渲染不出来），跳过 srt 分支而不是撞缺表异常。
    final bool hasSrtBooks = await appModel.database.hasSrtBooksTable;
    if (deleteLocalFiles) {
      // 先停止引用再销毁实体：正在播的那本若在本批里，句柄不放掉删除必然失败。
      // 会话身份对 EPUB 有声书是 bookKey、对纯字幕书是 srt uid，两种都塞进去。
      final List<String> sessionKeys = <String>[];
      for (final String key in toDelete) {
        if (key.startsWith('srt_')) {
          sessionKeys.add(key.substring(4));
          continue;
        }
        final String? bookKey = _parseBookKey(key);
        if (bookKey != null) sessionKeys.add(bookKey);
      }
      await appModel.audiobookSession.stopIfPlayingAny(sessionKeys);
    }
    for (final String key in toDelete) {
      if (key.startsWith('srt_')) {
        // 缺表守卫（见上面 [hasSrtBooks]）：不查询不存在的 srt_books。
        if (hasSrtBooks) {
          final SrtBook? book = await SrtBookRepository(
            appModel.database,
          ).findByUid(key.substring(4));
          if (book != null) {
            // SRT 不是漫画：保留原有单条删除路径与计数。统一弹窗没有同步范围，
            // 这里恒 keepLocalOnly（my-comic 无字幕表，此分支不可达）。
            final DeleteBookResult removed =
                await ReaderFushiSource.instance.deleteSrtShelfBook(
              db: appModel.database,
              book: book,
              scope: DeleteScope.keepLocalOnly,
              deleteLocalFiles: deleteLocalFiles,
              deleteStatistics: deleteStatistics,
            );
            if (removed.deleted) {
              succeeded++;
            } else {
              failed++;
            }
          }
        }
      } else {
        final String? bookKey = _parseBookKey(key);
        if (bookKey != null) {
          try {
            final MangaLibraryRemovalResult result = await removeMangaFromLibrary(
              db: appModel.database,
              bookKey: bookKey,
              // 测试壳 / 极端早期可能还没解析 AppPaths；在线与受管本地卷不需要
              // 这个根，只有 Local source 删原作时才必须（缺失会如实报失败）。
              localSourceRoot: appModel.appPathsOrNull?.localComicRoot,
              deleteLocalFiles: deleteLocalFiles,
              deleteStatistics: deleteStatistics,
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
            // 单部失败不影响其余作品（服务内已保证文件失败时 DB 行保留）。
            failed++;
            ErrorLogService.instance.log(
              'ReaderHistory.batchRemoveFromLibrary',
              error,
              stack,
            );
          }
        }
      }
      progress.value++;
    }
    if (!mounted) return;
    _refreshSrtBooks();
    ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    ref.invalidate(bookTagMapProvider);
    ref.invalidate(srtBookTagMapProvider);
    _shelfMapsFuture = _loadShelfMaps();
    _exitSelectionMode();
    FushiToast.show(
      msg: t.local_source_batch_remove_done(
        success: succeeded,
        failed: failed,
      ),
      severity: failed == 0 ? ToastSeverity.success : ToastSeverity.warning,
    );
  }

  /// 批量操作前把选中集收敛到真实存在的条目上，真剔掉了就明说。
  ///
  /// 与视频库同一纪律（见 `home_video_page._pruneStaleSelection`）：选中集不随库
  /// 变化剪枝，多选态期间同步下架 / 别处删除都会留下幽灵键，落库时撞外键——打标签
  /// 会把弹窗卡死在 loading、组合会静默失败、确认框数字是虚数。
  ///
  /// 存在性全集取**全部书架成员**而非可见集：被搜索或标签筛掉的书仍然存在，用户
  /// 先勾后筛是合法用法，不该被悄悄剔掉；但已移出书架（membership=false）的行
  /// 不再是书架动作的合法目标。
  ///
  /// 返回剔完后是否还有东西可做。
  Future<bool> _pruneStaleSelection() async {
    if (_selection.isEmpty) return false;
    final FushiDatabase db = appModel.database;
    // 存在性真值必须取自**书架选择键的来源表**，不是名字相近的 `media_items`：
    // 书架 EPUB 卡的选择键是 `ReaderFushiSource.mediaIdentifierFor(bookKey)`，
    // bookKey 的真值在 `epub_books`（`fushiBooksProvider` 也是从这里取的）；
    // `getAllMediaItems()` 是另一张表、另一套 mediaIdentifier 语义，拿它做判据
    // 会把全部选中项误判成幽灵键而整批剔光。
    final List<EpubBookMeta> epubBooks = await db.getEpubBookMetas();
    // v83：合集成员表 epub entryKey = `epub_books.uid`，而选择键解码出的身份仍是
    // bookKey。批量组合/加合集都在本剪枝之后立即落库，借同一批行顺带刷新
    // bookKey→uid 换算表（[_loadShelfMaps] 同款口径），保证写库前换算不吃旧值。
    _epubUidByKey = <String, String>{
      for (final EpubBookMeta row in epubBooks)
        if (row.uid.isNotEmpty) row.bookKey: row.uid,
    };
    final List<SrtBook> srtBooks = await SrtBookRepository(db).listAll();
    if (!mounted) return false;
    // BUG-2458：远端占位键的存在性真值是最近一次拉到的远端目录（占位卡就是从它
    // 渲染的），不在本地表里；不纳入就会被当幽灵键整批剔光。
    final _RemoteBookState? remoteState = _lastRemoteState;
    final int dropped = _selection.retainExisting(
      loose: <String>{
        // 书架批量动作只作用于书架成员：移出书架的选中项不再可操作。
        for (final EpubBookMeta row in epubBooks)
          if (row.isInLibrary)
            ReaderFushiSource.mediaIdentifierFor(row.bookKey),
        for (final SrtBook book in srtBooks) 'srt_${book.uid}',
        if (remoteState != null) ...<String>[
          for (final RemoteBookInfo book in remoteState.books)
            _remoteBookSelectionKey(book),
          for (final RemoteAudiobookInfo book in remoteState.srtAudiobooks)
            _remoteSrtSelectionKey(book),
        ],
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
    // 幽灵键会让 bookTags 外键插入抛异常，弹窗把落库 await 在 loading 态里，
    // 一抛就永远转圈（卡死）。必须在开弹窗前剔干净。
    if (!await _pruneStaleSelection() || !mounted) return;
    // 共享标签选择器（搜索 / 一键新建 / 三态）。散卡按 epub=bookKey、srt=uid 成
    // MediaRef。2026-11-05：合集已删除，选择器只作用于散卡。
    final List<MediaRef> media = <MediaRef>[
      for (final String key in _selectedLocalKeys)
        if (key.startsWith('srt_'))
          MediaRef(kind: MediaKind.srt, entryKey: key.substring(4))
        else if (_parseBookKey(key) case final String bookKey)
          MediaRef(kind: MediaKind.epub, entryKey: bookKey),
    ];
    final TagTargets targets = TagTargets(media: media);
    if (targets.isEmpty) return;
    await showTagPicker(context, targets: targets);
    if (!mounted) return;
    ref.invalidate(allTagsProvider);
    ref.invalidate(bookTagMapProvider);
    ref.invalidate(srtBookTagMapProvider);
    ref.invalidate(filteredBookIdsProvider);
    ref.invalidate(filteredSrtBookUidsProvider);
  }

  Future<void> _confirmDeleteSrtBook(SrtBook book) async {
    final bool hasLocalFiles =
        await resolveAudiobookHasLocalFiles(book.audioPaths) ||
            (book.bookKey.isNotEmpty &&
                await ReaderFushiSource.instance.hasLocalFiles(
                  db: appModel.database,
                  bookKey: book.bookKey,
                ));
    if (!mounted) return;
    // P4：确认弹窗给人看，书名过门面（删除本体仍按 raw bookKey/uid 身份执行）。
    final DeleteDecision? decision = await _confirmMediaDelete(
      title: t.srt_delete_title,
      message: t.srt_delete_confirm(title: _srtDisplayTitle(book)),
      disclosure: buildDeletionDisclosure(
        target: DeletionDisclosureTarget.shelfBook,
      ),
      localFilesSubtitle:
          hasLocalFiles ? t.delete_local_files_audio_desc : null,
      // 纯字幕书（bookKey 空）不摆「同时删除统计数据」：它的 legacy 阅读统计 /
      // 计数行与墓碑只能按 title 定位，同名 EPUB 的统计会被连坐删掉。
      statisticsSubtitle:
          ReaderFushiSource.srtBookOffersStatisticsDeletion(book)
              ? _statisticsSubtitle
              : null,
    );
    if (decision == null) return;
    final DeleteScope scope = decision.scope;

    if (decision.deleteLocalFiles) {
      // 先停止引用再销毁实体（会话身份：srt-backed 是 uid，EPUB 是 bookKey）。
      await appModel.audiobookSession.stopIfPlayingAny(<String>[
        book.uid,
        if (book.bookKey.isNotEmpty) book.bookKey,
      ]);
    }
    // BUG-3101：按身份只走一条删除路径（配对了 EPUB 的走 deleteBook 整本删，纯
    // 字幕书走 SrtBookRepository，删除范围在两条路上都落地）。以前 deleteBook 之后
    // 又按 uid 删一次 srt 行，行已被级联删掉、回报 0 行，于是每次都弹「删除书籍失败」。
    final DeleteBookResult result =
        await ReaderFushiSource.instance.deleteSrtShelfBook(
      db: appModel.database,
      book: book,
      scope: scope,
      deleteLocalFiles: decision.deleteLocalFiles,
      deleteStatistics: decision.deleteStatistics,
    );
    if (mounted) {
      reportLocalFileDeleteFailures(
        result.localFiles,
        source: 'ReaderHistory.deleteSrtBookLocalFiles',
      );
      // 2026-10 体验优化：单本删除此前成功失败都静默；没删到行（已被别处删掉 /
      // 写库失败）时卡片原样留着，用户只会以为没点上。
      if (!result.deleted) {
        final String reason = result.failureReason ?? '';
        FushiToast.show(
          msg: reason.isEmpty
              ? t.epub_delete_error
              : '${t.epub_delete_error}: $reason',
          severity: ToastSeverity.error,
        );
      } else {
        FushiToast.show(
          msg: t.batch_delete_success(n: 1),
          severity: ToastSeverity.success,
        );
      }
      _refreshSrtBooks();
      ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
      _rebuild(() {});
    }
  }

  /// 该书当前是否就是活动后台听书会话。
  bool _isBackgroundListeningBook(String bookKey) {
    final session = appModel.audiobookSession;
    return session.isActive && session.book?.bookKey == bookKey;
  }

  /// 书架长按菜单切「后台听书」（TODO-291 阶段2）。
  /// - 该书已是活动会话 → 停止后台听书。
  /// - 否则 → 启动该书的后台听书会话（无正在播用该书启动；有别的书在播则顶掉切到该书），
  ///   并拉起悬浮窗。无可播放音频时提示。
  Future<void> _toggleFloatingLyricFromShelf(String bookKey) async {
    Navigator.pop(context);
    if (_isBackgroundListeningBook(bookKey)) {
      await appModel.stopBackgroundListening();
      if (!mounted) return;
      // 2026-10 体验优化：停止后台听书此前静默，用户不确定点没点上。
      FushiToast.show(
        msg: t.floating_lyric_stop_action,
        severity: ToastSeverity.info,
      );
      _rebuild(() {});
      return;
    }
    final BackgroundListenResult result =
        await appModel.startBackgroundListening(bookKey);
    if (!mounted) return;
    switch (result) {
      case BackgroundListenResult.started:
        break;
      case BackgroundListenResult.noAudio:
        FushiToast.show(
            msg: t.floating_lyric_no_audio, severity: ToastSeverity.error);
        break;
      case BackgroundListenResult.loadFailed:
        FushiToast.show(
            msg: t.audiobook_load_error, severity: ToastSeverity.error);
        break;
    }
    _rebuild(() {});
  }

  /// 漫画卡长按菜单「删除」= 从漫画书架移出（票 02）。
  ///
  /// 与作品页、书架批量共用票 01 的统一弹窗：标题、单本说明、两个默认不勾选的
  /// 选项。在线漫画先停下载任务，勾选「同时删除本地文件」时删 Download library
  /// 里的已下载章节；本地 Manga 则删 Local source root 里的原作。文件成功后
  /// 才删库，失败时作品留在书架。History 保留。
  Future<void> _confirmMangaShelfDelete(String bookKey) async {
    Navigator.pop(context);
    final MangaLibraryRemovalDecision? decision =
        await showMangaShelfRemovalDialog(
      context,
      message: t.manga_series_remove_confirm,
      localFilesSubtitle: t.delete_local_files_download_desc,
      statisticsSubtitle: t.delete_statistics_manga_desc,
    );
    if (decision == null || !mounted) return;
    try {
      final MangaLibraryRemovalResult result = await removeMangaFromLibrary(
        db: appModel.database,
        bookKey: bookKey,
        localSourceRoot: appModel.appPathsOrNull?.localComicRoot,
        deleteLocalFiles: decision.deleteLocalFiles,
        deleteStatistics: decision.deleteStatistics,
        downloadService: appModel.mangaDownloadService,
      );
      if (!mounted) return;
      if (!result.removed) {
        final String reason = result.failureMessage;
        FushiToast.show(
          msg: reason.isEmpty
              ? t.epub_delete_error
              : '${t.epub_delete_error}: $reason',
          severity: ToastSeverity.error,
        );
        return;
      }
      FushiToast.show(
        msg: t.batch_delete_success(n: 1),
        severity: ToastSeverity.success,
      );
      _refreshSrtBooks();
      ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
      _rebuild(() {});
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'ReaderHistory.removeMangaFromLibrary',
        error,
        stack,
      );
      if (mounted) {
        FushiToast.show(
          msg: t.epub_delete_error,
          severity: ToastSeverity.error,
        );
      }
    }
  }

  Future<void> _confirmDeleteEpub(MediaItem item, String bookKey) async {
    Navigator.pop(context);
    final bool hasLocalFiles = await ReaderFushiSource.instance
        .hasLocalFiles(db: appModel.database, bookKey: bookKey);
    if (!mounted) return;
    // P4：确认弹窗给人看，书名过门面（删除本体仍按 raw bookKey 身份执行）。
    final DeleteDecision? decision = await _confirmMediaDelete(
      title: t.epub_delete_title,
      message: t.srt_delete_confirm(
        title: displayTitleForBook(item: item, rawTitle: item.title),
      ),
      disclosure: buildDeletionDisclosure(
        target: DeletionDisclosureTarget.shelfBook,
      ),
      localFilesSubtitle:
          hasLocalFiles ? t.delete_local_files_audio_desc : null,
      statisticsSubtitle: _statisticsSubtitle,
    );
    if (decision == null) return;

    if (decision.deleteLocalFiles) {
      // 先停止引用再销毁实体：正在播的就是这本时，句柄不放掉删除必然失败。
      await appModel.audiobookSession.stopIfPlayingAny(<String>[bookKey]);
    }
    final DeleteBookResult result = await ReaderFushiSource.instance.deleteBook(
      db: appModel.database,
      bookKey: bookKey,
      scope: decision.scope,
      deleteLocalFiles: decision.deleteLocalFiles,
      deleteStatistics: decision.deleteStatistics,
    );
    if (!mounted) return;
    reportLocalFileDeleteFailures(
      result.localFiles,
      source: 'ReaderHistory.deleteEpubLocalFiles',
    );
    if (!result.deleted) {
      // TODO-1359：不再只弹笼统的「删除书籍失败」——把 deleteBook 回报的原因（同时已
      // 写入 ErrorLogService，可在日志页导出）拼进 toast，让用户知道为什么删不掉。
      final String reason = result.failureReason ?? '';
      FushiToast.show(
        msg: reason.isEmpty
            ? t.epub_delete_error
            : '${t.epub_delete_error}: $reason',
        severity: ToastSeverity.error,
      );
      return;
    }
    // 2026-10 体验优化：成功也给反馈（与批量删除同一文案）。
    FushiToast.show(
      msg: t.batch_delete_success(n: 1),
      severity: ToastSeverity.success,
    );
    _refreshSrtBooks();
    ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    _rebuild(() {});
  }

  /// 书卡 / 配对字幕书卡「重置阅读状态」：先收起长按菜单，弹确认框（可选撤销最近
  /// 一次会话，默认不动学习记录），确认后经 [resetBookReadingState] 落库
  /// （位置写回开头而不是删行——删行会被同步通道从对端灌回，见该函数文件头），
  /// 再让书列表 / 最近阅读时刻 / 读完集合三份缓存一起失效。
  Future<void> _resetBookReadingState(
    MediaItem item,
    String bookKey, {
    String? srtUid,
  }) async {
    Navigator.pop(context);
    if (bookKey.isEmpty) return;
    final StudyRecordResetScope? records = await showLibraryProgressResetDialog(
      context,
      title: t.library_progress_reset_action,
      message: t.library_progress_reset_book_message,
      itemTitle: displayTitleForBook(item: item, rawTitle: item.title),
    );
    if (records == null || !mounted) return;
    try {
      await resetBookReadingState(
        db: appModel.database,
        bookKey: bookKey,
        title: item.title,
        extraStatKeys: <String>{if (srtUid != null) srtUid},
        records: records,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHistory.resetReadingState', e, stack);
      if (!mounted) return;
      _afterReadingStateReset();
      FushiToast.show(
        msg: t.library_progress_reset_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    if (!mounted) return;
    _afterReadingStateReset();
    FushiToast.show(
      msg: t.library_progress_reset_done,
      severity: ToastSeverity.success,
    );
  }

  /// 重置阅读状态之后：书列表（进度）、最近阅读时刻、读完集合与书架映射一起重取。
  void _afterReadingStateReset() {
    ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    ref.invalidate(bookLastReadAtProvider);
    ref.invalidate(completedEpubBookKeysProvider);
    _shelfMapsFuture = _loadShelfMaps();
    _rebuild(() {});
  }

  /// 书架卡片菜单「重新导入」（字幕书）：音频 + 字幕两半一起换。
  ///
  /// **先按播放侧真相分流**，这是旧实现最要命的 bug：EPUB 有声书除了 `audiobooks`
  /// 行还会落一条配对的 `srt_books` 行（`srtbook_epub_<bookKey>`，TODO-894 为打通
  /// 同步导出），书架把它渲染成 SRT 卡片，于是这个菜单项也出现在**有声书**卡上。
  /// 旧实现无条件走 [SrtBookRepository.replaceAudio] 写 `SrtBooks.audioPaths`，
  /// 而 [AudiobookSessionLauncher.resolve] 是**先查 `Audiobooks` 再回退 `SrtBooks`**
  /// 的——命中 Audiobooks 就返回，刚写的新音频永远读不到。用户报的「导入音频没用」
  /// 就是这条：写了，但播放侧根本不看那一列。
  ///
  /// 判据用「该 bookKey 是否有 `audiobooks` 行」而不是 uid 形态：它正是 resolve 的
  /// 判据本身，与播放侧逐字同源，不会因为 uid 命名将来变形而悄悄漂开。
  Future<void> _openSrtBookReimport(SrtBook book) async {
    final String bookKey = book.bookKey;
    final AudiobookRow? audiobookRow = bookKey.isEmpty
        ? null
        : await appModel.database.getAudiobookByBookKey(bookKey);
    if (!mounted) return;

    if (audiobookRow != null) {
      // 播放侧读 Audiobooks：交给管那张表的对话框（它音频/字幕两半都能换）。
      await _openAudiobookImportForKey(bookKey);
      return;
    }

    final SrtBookRepository repo = SrtBookRepository(appModel.database);
    final SrtBookReimportOutcome? outcome =
        await showAppDialog<SrtBookReimportOutcome>(
      context: context,
      builder: (_) => SrtBookReimportDialog(
        book: book,
        db: appModel.database,
        repo: repo,
      ),
    );
    if (outcome == null || !mounted) return;
    _refreshSrtBooks();
    ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    _rebuild(() {});
  }

  Future<List<String>> _pickSrtAudioFiles() async {
    final Set<String> audioExtensions = AudiobookStorage.audioExtensions
        .map((String ext) => ext.replaceFirst('.', ''))
        .toSet();
    final List<String> paths = await pickRealFilePaths(
      context: context,
      appModel: appModel,
      allowedExtensions: audioExtensions,
    );
    paths.sort(compareAudioFilePath);
    return paths;
  }

  Future<void> _openAudiobookImport(MediaItem item, String bookKey) async {
    Navigator.pop(context);
    await _openAudiobookImportForKey(bookKey);
  }

  Future<void> _openAudiobookStudio(String bookKey) async {
    Navigator.pop(context);
    await openTtsStudioPage(context, appModel: appModel, bookKey: bookKey);
    if (mounted) _rebuild(() {});
  }

  /// 打开 [AudiobookImportDialog] 本体（调用方负责先收起自己的菜单）。
  /// 卡菜单入口与字幕书「重新导入」的分流入口共用，避免第二处手抄 extractDir 查询。
  Future<void> _openAudiobookImportForKey(String bookKey) async {
    final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
    if (!mounted) return;
    await showAppDialog<bool>(
      context: context,
      builder: (_) => AudiobookImportDialog(
        prefs: appModel.prefsRepo,
        bookKey: bookKey,
        repo: AudiobookRepository(appModel.database),
        extractDir: row?.extractDir,
      ),
    );
    if (mounted) {
      _refreshSrtBooks();
      _rebuild(() {});
    }
  }

  /// 文件拖入书架后的路由：分类 → 命中测试 → 决策 → 打开对应对话框/提示。
  /// [globalPosition] 为 [FushiFileDropTarget] 透出的 Flutter global/view 坐标，
  /// 可直接与卡片登记表（同坐标系屏幕矩形）命中测试。
  Future<void> _handleShelfDrop(
    List<String> paths,
    Offset globalPosition,
  ) async {
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;

    // 图片型 .zip（一包页图的漫画）与 Yomitan 词典包同形，要真读包才分得出——与导入
    // 对话框的分派同一判据，两条入口对「这算不算漫画」回答一致。但那次「真读包」是
    // **同步解整个压缩包**，原来就长在下面 classifyDroppedFiles 的注入谓词里，也就
    // 长在 desktop_drop 回调的同步栈上：拖个大包进来 UI 线程直接卡死。先离线程一次
    // 性判完（[probeDroppedImageArchives]），再把结果当同步谓词喂回去，分类函数保持
    // 纯函数不变。
    //
    // 漫画库（[_mangaOnly]）落点偏好漫画：`.epub` 也开包，图片型 EPUB 直接归漫画，
    // 不再先进书籍导入框、再被告知「这看起来是漫画」；`.pdf` 直接归漫画。
    final Map<String, bool> imageArchives =
        await probeDroppedImageArchives(paths, preferManga: _mangaOnly);
    if (!mounted) return;

    // 目录（漫画页图文件夹）没有扩展名，纯分类函数分不出来——把真实文件系统判据
    // 注入进去（分类层本身仍不碰 IO）。
    final DroppedFiles files = classifyDroppedFiles(
      paths,
      isDirectory: (String pth) => Directory(pth).existsSync(),
      isImageArchive: (String pth) => imageArchives[pth] ?? false,
      preferManga: _mangaOnly,
    );
    debugPrint(
      '[fushi-drop] [reader-shelf] classified '
      'books=${files.books.length} subtitles=${files.subtitles.length} '
      'audios=${files.audios.length} videos=${files.videos.length} '
      'mangas=${files.mangas.length} '
      'unsupportedMangas=${files.unsupportedMangas.length} '
      'dictionaries=${files.dictionaries.length} unknown=${files.unknown.length} '
      'global=$globalPosition',
    );
    final String? hitBookKey = _cardDropRegistry.hitTest(globalPosition);
    // 漫画库是同一个页面的 mangaOnly 壳，但落点语义不同（见 DropSurface.manga）。
    final DropIntent intent = decideDropIntent(
      surface: _mangaOnly ? DropSurface.manga : DropSurface.books,
      files: files,
      cardHit: hitBookKey != null,
    );
    // 跨模块落点一次快照。被关掉的模块不再打开它的导入对话框，而是给一条与
    // [DropIntent.unsupportedSurface] 同形态的 SnackBar——拖放没有「不渲染入口」
    // 这个选项（落点就是整块书架），所以必须给可见反馈，绝不静默吞掉。
    final ModuleVisibility modules = _moduleVisibility;
    void showModuleDisabled() {
      // 闭包里重判一次 mounted：本函数在 await 之后才走到这里，闭包体外的流分析
      // 结论传不进来（use_build_context_synchronously）。
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(FushiSnackBar(content: Text(t.module_disabled_hint)));
    }

    switch (intent) {
      // 书架/漫画库不产出这个意图：目录在这两个表面仍是「一本漫画的页图文件夹」
      // （importNewManga），把整个目录登记成扫描根是视频页的语义。列出来只为让
      // `decideDropIntent` 以后给 books 也加上文件夹语义时，这里编译期就红。
      case DropIntent.addFolderAsSource:
        debugPrint('[fushi-drop] [reader-shelf] intent=addFolderAsSource '
            '(not produced on this surface)');
      case DropIntent.importNewBook:
        // 一本书：同批的字幕 / 音频一起预填（有声书）。多本：逐本弹导入框，不再只导
        // 第一本、其余静默丢掉；此时字幕 / 音频没法确定归哪一本，不预填。
        if (files.books.length == 1) {
          _openBookImportPrefilled(
            epubPath: files.books.single,
            subtitlePath:
                files.subtitles.isNotEmpty ? files.subtitles.first : null,
            audioPaths: files.audios,
          );
        } else {
          unawaited(_openBookImportsInSequence(files.books));
        }
      case DropIntent.importNewManga:
        // 漫画（.mokuro / .cbz / 页图目录 / 图片型 zip）走漫画自己的导入对话框。
        // 决策层本来就把漫画和书分成了两个 intent，此前两个 intent 却落到同一个
        // 对话框；现在落点跟着 intent 走，载体身份不再在半路丢失。
        if (!modules.isEnabled(ModuleId.manga)) {
          showModuleDisabled();
          return;
        }
        _openMangaImportPrefilled(mangaPaths: files.mangas);
      case DropIntent.unsupportedMangaArchive:
        debugPrint(
          '[fushi-drop] [reader-shelf] intent=unsupportedMangaArchive',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          FushiSnackBar(content: Text(t.drag_drop_manga_archive_unsupported)),
        );
      case DropIntent.attachToBookCard:
        // 往书卡上拖音频/字幕 = 给这本书挂有声书，属听书模块。
        if (!modules.isEnabled(ModuleId.listening)) {
          showModuleDisabled();
          return;
        }
        _openAudiobookPrefilled(
          bookKey: hitBookKey!,
          audioPaths: files.audios,
          alignmentPath:
              files.subtitles.isNotEmpty ? files.subtitles.first : null,
        );
      case DropIntent.needCardTarget:
        debugPrint('[fushi-drop] [reader-shelf] intent=needCardTarget');
        ScaffoldMessenger.of(context).showSnackBar(
          FushiSnackBar(content: Text(t.drag_drop_need_card_target)),
        );
      case DropIntent.importNewVideo:
      case DropIntent.importNewPlaylist:
      case DropIntent.importVideoUrl:
      case DropIntent.importTorrent:
        // 视频 / 种子导入已随非漫画域移除。
        break;
      case DropIntent.unsupportedSurface:
        debugPrint('[fushi-drop] [reader-shelf] intent=unsupportedSurface');
        ScaffoldMessenger.of(context).showSnackBar(
          FushiSnackBar(content: Text(t.drag_drop_unsupported_on_books)),
        );
      case DropIntent.attachToVideoCard:
      case DropIntent.ignore:
        break;
    }
  }

  /// 拖入书文件 → 打开 [BookImportDialog]，预填 EPUB（及可选字幕）路径。
  /// 复用 [ReaderFushiSource.buildBookImportButton] 的 repo/打开/刷新范式。
  ///
  /// 返回对话框结果：true 已导入、false 这一本没导（同名取消 / 转交漫画未导）、
  /// null 用户关掉了对话框（[_openBookImportsInSequence] 据此停止后续）。
  Future<bool?> _openBookImportPrefilled({
    required String epubPath,
    required String? subtitlePath,
    List<String> audioPaths = const <String>[],
  }) async {
    final bool? imported = await showAppDialog<bool>(
      context: context,
      builder: (_) => BookImportDialog(
        prefs: appModel.prefsRepo,
        repo: SrtBookRepository(appModel.database),
        audiobookRepo: AudiobookRepository(appModel.database),
        db: appModel.database,
        initialEpubPath: epubPath,
        initialSubtitlePath: subtitlePath,
        initialAudioPaths: audioPaths.isEmpty ? null : audioPaths,
      ),
    );
    if (imported == true && mounted) {
      _refreshSrtBooks();
      ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    }
    return imported;
  }

  /// 多本书同时拖入：逐本打开 [BookImportDialog]（每本都要定标题 / 处理同名）。
  ///
  /// 只有用户**关掉对话框**（取消 / 返回键 / 点遮罩，结果 null）才停止后续：那是
  /// 「剩下的都不要了」。同名询问里选「否」只是这一本不导（对话框回 false），继续下一本
  /// ——否则一本重名就把后面所有书静默丢掉，正是这里要消灭的行为。
  Future<void> _openBookImportsInSequence(List<String> bookPaths) async {
    for (final String bookPath in bookPaths) {
      if (!mounted) return;
      final bool? imported = await _openBookImportPrefilled(
        epubPath: bookPath,
        subtitlePath: null,
      );
      if (imported == null) return;
    }
  }

  /// 拖入漫画 → 打开 [MangaImportDialog]，预填漫画路径（目录 / .cbz / .mokuro /
  /// 图片型 zip / 漫画库里的图片型 epub 与 pdf）。多个路径时对话框进逐卷批量模式。
  /// 刷新范式与 [_openBookImportPrefilled] 一致：漫画与书共用 `EpubBooks` 表和同一块
  /// 书架，故失效的 provider 也相同。
  Future<void> _openMangaImportPrefilled({
    required List<String> mangaPaths,
  }) async {
    // 页图文件夹走 Local source：先复制进 `local` 再登记，原始文件夹保留
    // （ADR 0013）。`.mokuro` / CBZ / 图片型 zip / PDF 等仍走漫画导入对话框；
    // CBZ 的 local 登记属于 ticket 07。
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
          severity: imported > 0
              ? ToastSeverity.success
              : ToastSeverity.error,
        );
      }
    }

    if (dialogPaths.isEmpty) {
      if (mounted && localFolders.isNotEmpty) {
        _refreshSrtBooks();
        ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
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
      _refreshSrtBooks();
      ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    }
  }

  /// 拖入字幕/音频到书卡 → 打开 [AudiobookImportDialog] 附加到该书，预填音频/对齐路径。
  /// 复用 [_openAudiobookImport] 的 extractDir 取法与刷新范式（此处无外层对话框需 pop）。
  Future<void> _openAudiobookPrefilled({
    required String bookKey,
    required List<String> audioPaths,
    required String? alignmentPath,
  }) async {
    final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
    if (!mounted) return;
    await showAppDialog<bool>(
      context: context,
      builder: (_) => AudiobookImportDialog(
        prefs: appModel.prefsRepo,
        bookKey: bookKey,
        repo: AudiobookRepository(appModel.database),
        extractDir: row?.extractDir,
        initialAudioPaths: audioPaths.isEmpty ? null : audioPaths,
        initialAlignmentPath: alignmentPath,
      ),
    );
    if (mounted) {
      _rebuild(() {});
    }
  }

}

class _AudiobookInfo {
  const _AudiobookInfo({required this.hasAudiobook, required this.healthKind});
  final bool hasAudiobook;
  final HealthKind healthKind;
}

/// 书架批量删除的阻塞式进度弹窗（2026-10 体验优化）。
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
                // 设计系统分派版：MD3 走 M3E 波浪轨道，Apple 走细轨。
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
