/// [DiscoveryDomainImporters] 里纯 Dart 的漫画图包导入原语。app 的生产装配
/// （`discovery_import_production.dart`）使用这一份。
///
/// 小说 / 文本 / 有声书 / 游戏域已随 my-comic 独立化删除；其他宿主接不了的域用
/// [unsupportedDiscoveryImporter] 如实挡下。
///
/// 策略全部是 `DuplicatePolicy.skip()`：后台批量入库不弹交互，同名已在库即跳过
/// （返回 null，任务显示 0 条新增）。
library;

import 'package:my_comic_core/my_comic_core.dart';
import 'package:my_comic_engine/media/discovery/import/discovery_import_plan.dart';
import 'package:my_comic_engine/media/manga/book_title_conflict.dart';
import 'package:my_comic_engine/media/manga/manga_archive_importer.dart';

/// 漫画图包：`MangaArchiveImporter.importArchive`（自建 staging、7-Zip/内置解码
/// 解包、识别包内 `.mokuro` sidecar、防穿越、失败回滚）。它的默认策略是
/// `.suffix()`（适合用户手动点的导入）；自动入库留副本会让重复下载悄悄堆出
/// 「XXX (2)」「XXX (3)」，所以这里显式 skip。
Future<String?> importDiscoveryMangaArchive(
  MyComicDatabase db,
  String archivePath,
) async {
  try {
    return await MangaArchiveImporter.importArchive(
      db: db,
      archivePath: archivePath,
      title: discoveryImportStem(archivePath),
      policy: const DuplicatePolicy.skip(),
    );
  } on DuplicateImportCancelledException {
    return null;
  }
}

/// 本宿主接不了的域原语：抛 [DiscoveryImportBlocker.unsupportedOnThisHost]，
/// [what] 进 detail（如 `pdf` / `game`）。任务落成 needsAttention 并带稳定原因码，
/// 而不是假装导入了 0 条。
Never unsupportedDiscoveryImporter(String what, String path) =>
    throw DiscoveryImportBlockedException(
      DiscoveryImportBlocker.unsupportedOnThisHost,
      '$what: ${discoveryImportFileName(path)}',
    );

String discoveryImportFileName(String path) {
  final String normalized = path.replaceAll('\\', '/');
  return normalized.substring(normalized.lastIndexOf('/') + 1);
}

String discoveryImportStem(String path) {
  final String base = discoveryImportFileName(path);
  final int dot = base.lastIndexOf('.');
  return dot <= 0 ? base : base.substring(0, dot);
}
