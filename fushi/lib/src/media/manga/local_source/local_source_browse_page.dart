import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/manga_cover_placeholder.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/online/online_source_browse_page.dart';
import 'package:fushi/src/media/online/online_source_error_text.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/shelf_sort.dart' show naturalCompare;
import 'package:fushi_engine/media/manga/local_source/local_source_cover.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';

/// 内置「本地图源」的浏览页：进入即扫描 Local source root（`local`），以
/// 封面网格展示扫描结果。
///
/// 只展示、不登记：点封面进作品页（未入库的走
/// [LocalSourceMangaSeriesTarget]），用户在作品页显式「加入书架」才写 Library。
///
/// 外壳完全复用在线源浏览页（[OnlineSourceBrowsePage]）：返回键、浮动标题胶囊、
/// 搜索框、封面网格、加载骨架与错误占位都是同一套；本地图源没有「热门 / 最新」
/// 列表与筛选，适配器返回空列表 / `hasFilters = false` 即可。
class LocalSourceBrowsePage extends ConsumerStatefulWidget {
  const LocalSourceBrowsePage({super.key});

  @override
  ConsumerState<LocalSourceBrowsePage> createState() =>
      _LocalSourceBrowsePageState();
}

class _LocalSourceBrowsePageState extends ConsumerState<LocalSourceBrowsePage> {
  late final AppModel _appModel;
  late final LocalSourceBrowseCatalog _catalog;

  @override
  void initState() {
    super.initState();
    _appModel = ref.read(appProvider);
    _catalog = LocalSourceBrowseCatalog(
      root: _appModel.appPaths.localComicRoot,
      db: _appModel.database,
    );
  }

  @override
  Widget build(BuildContext context) =>
      OnlineSourceBrowsePage<LocalSourceManga>(catalog: _catalog);
}

/// Local source root 读不了（目录不存在 / 无权限）时抛给浏览页的错误态。
class LocalSourceRootUnavailable implements Exception {
  const LocalSourceRootUnavailable(this.path, [this.cause]);

  final String path;
  final Object? cause;

  @override
  String toString() =>
      'LocalSourceRootUnavailable($path)${cause == null ? '' : ': $cause'}';
}

/// 「本地图源」在共用源浏览页里的差异：一次扫描的结果就是全部内容。
///
/// [prepare] 每次进页扫描一次（不做文件监视、不做增量缓存），扫描完成即返回，
/// 让网格先显示结果；随后在后台**逐个**给缺封面的作品生成 `cover.jpg`，每完成
/// 一部就通过 [changes] 通知页面更新对应卡片。生成失败的作品保持占位，下次
/// 进页重试。扫描原地读取，不复制、不移动任何文件。
class LocalSourceBrowseCatalog extends OnlineSourceCatalog<LocalSourceManga> {
  LocalSourceBrowseCatalog({required this.root, required this.db});

  /// Local source root（`<Content root>/local`）。
  final Directory root;

  /// 已登记作品的 `coverPath` 同步（生成封面的副作用）。
  final FushiDatabase db;

  List<LocalSourceManga> _scanned = const <LocalSourceManga>[];
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);
  Future<void> _coversGenerated = Future<void>.value();
  int _coverGenerationId = 0;

  @override
  Listenable get changes => _revision;

  /// 本轮后台封面补齐完成（进页时启动一次；测试可等待它）。
  Future<void> get coversGenerated => _coversGenerated;

  @override
  String get title => t.local_source_title;

  @override
  String get searchHint => t.local_source_search_hint;

  @override
  String get keyPrefix => 'local_source';

  @override
  Future<void> prepare() async {
    // 目录不在了（Content root 掉线 / 被删）是错误态，不是空态：空态只表示
    // 「文件夹里确实还没有漫画」。先探一次根目录，让读取失败冒泡给页面。
    if (!await root.exists()) {
      throw LocalSourceRootUnavailable(root.path);
    }
    try {
      root.listSync(followLinks: false);
    } on FileSystemException catch (error) {
      throw LocalSourceRootUnavailable(root.path, error);
    }
    _scanned = await scanLocalSourceRoot(root);
    _coversGenerated = _generateMissingCovers();
  }

  /// 后台逐部补齐封面：不阻塞首屏；成功后替换扫描条目并通知页面刷新。
  ///
  /// 单部失败（坏页 / 写入失败）只跳过它，占位保留，下次进页再试。重复
  /// [prepare] 时旧循环在下一个作品前自停，避免两轮同时写同一批封面。
  Future<void> _generateMissingCovers() async {
    final int generation = ++_coverGenerationId;
    final LocalSourceCoverService service = LocalSourceCoverService(db: db);
    for (final LocalSourceManga manga in List<LocalSourceManga>.of(_scanned)) {
      if (generation != _coverGenerationId) return;
      try {
        final LocalSourceCoverResult result = await service
            .generateMissingCover(manga);
        if (generation != _coverGenerationId) return;
        final String? cover = result.coverRelativePath;
        if (cover == null || cover == manga.coverRelativePath) continue;
        _scanned = <LocalSourceManga>[
          for (final LocalSourceManga item in _scanned)
            p.equals(item.directoryPath, manga.directoryPath)
                ? withLocalSourceCoverRelativePath(item, cover)
                : item,
        ];
        _revision.value++;
      } on Object {
        // 保持占位；下次进入本地图源时重新扫描并重试。
      }
    }
  }

  @override
  void dispose() {
    // 让在途的后台循环在下一个作品前停下，之后不再触碰已释放的 notifier。
    _coverGenerationId++;
    _revision.dispose();
    super.dispose();
  }

  @override
  List<OnlineBrowseListing> get listings => const <OnlineBrowseListing>[];

  @override
  bool get hasFilters => false;

  @override
  Future<OnlineBrowseFilterTarget?> editFilters(BuildContext context) async =>
      null;

  @override
  Future<OnlineBrowsePageResult<LocalSourceManga>> fetch(
    OnlineBrowseQuery query,
    int page,
  ) async {
    final List<LocalSourceManga> matched = filterByMediaSearch<LocalSourceManga>(
      _scanned,
      query.isSearch ? query.text : '',
      (LocalSourceManga manga) => <String>[manga.title],
    );
    matched.sort(
      (LocalSourceManga a, LocalSourceManga b) =>
          naturalCompare(a.title, b.title),
    );
    return (items: matched, hasNextPage: false);
  }

  @override
  String keyOf(LocalSourceManga item) => item.directoryPath;

  @override
  String titleOf(LocalSourceManga item) => item.title;

  @override
  Widget buildCover(BuildContext context, LocalSourceManga item) {
    // 封面沿用 `cover.jpg/jpeg/png` 约定；缺失时用现有占位封面（扫描时不假装
    // 某一页是封面）。
    final String? relative = item.coverRelativePath;
    if (relative == null) return const MangaCoverPlaceholder();
    final String path = p.join(item.directoryPath, relative);
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      // 坏封面 / 扫描后被移走的文件退回占位，不让网格解码报错。
      errorBuilder: (_, Object error, __) =>
          const MangaCoverPlaceholder(),
    );
  }

  @override
  void Function(BuildContext context, LocalSourceManga item)? get openDetail =>
      (BuildContext context, LocalSourceManga manga) {
        Navigator.of(context).push(
          adaptivePageRoute<void>(
            context: context,
            builder: (BuildContext context) =>
                MangaSeriesPage(target: LocalSourceMangaSeriesTarget(manga)),
          ),
        );
      };

  @override
  Widget buildVerifyAction(
    BuildContext context, {
    required Object? error,
    required Future<void> Function() onVerified,
  }) => const SizedBox.shrink();

  @override
  String describeError(Object error) =>
      error is LocalSourceRootUnavailable
      ? t.local_source_scan_failed
      : describeOnlineSourceError(error);

  /// 空态：不搜索时是书架图标 +「尚未发现任何漫画」；搜索无命中仍是放大镜。
  @override
  IconData emptyIcon({required bool searching}) =>
      searching ? FushiIcons.searchOff : FushiIcons.books;

  @override
  String emptyTextFor({required bool searching}) =>
      searching ? t.no_search_results : t.local_source_empty;
}
