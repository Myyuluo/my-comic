/// [DiscoveryDomainImporters] 的 my-comic 生产装配：只保留漫画域。
///
/// 小说 / PDF / 有声书 / 游戏域已删除，发现页直链下载的自动入库只剩漫画图包
/// 一条路径（cbz/cbr/cb7/rar/zip，`.mokuro` sidecar 识别在引擎域导入器内部完成）。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/discovery/import/discovery_engine_importers.dart';
import 'package:fushi_engine/media/discovery/import/discovery_import_executor.dart';

DiscoveryDomainImporters buildProductionDiscoveryImporters({
  required FushiDatabase db,
}) {
  return DiscoveryDomainImporters(
    importMangaArchive: (String archivePath) =>
        importDiscoveryMangaArchive(db, archivePath),
  );
}
