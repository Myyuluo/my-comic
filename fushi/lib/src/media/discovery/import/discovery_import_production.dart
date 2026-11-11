/// [DiscoveryDomainImporters] 的 my-comic 生产装配：只保留漫画域。
///
/// Ticket 04 删除小说 / PDF / 有声书 / 游戏域后，发现页直链下载的自动入库
/// 只剩漫画图包一条路径（cbz/cbr/cb7/rar/zip，`.mokuro` sidecar 识别在
/// 引擎域导入器内部完成）。其余端口保留签名但一律返回「跳过」/ 不支持，
/// 因为执行器仍是引擎共享类型；发现页 UI 也只会在漫画域发起下载。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart'
    show DiscoveryImportOutcome;
import 'package:fushi_engine/media/discovery/import/discovery_engine_importers.dart';
import 'package:fushi_engine/media/discovery/import/discovery_import_executor.dart';
import 'package:fushi_engine/media/discovery/import/discovery_import_plan.dart';

DiscoveryDomainImporters buildProductionDiscoveryImporters({
  required FushiDatabase db,
}) {
  return DiscoveryDomainImporters(
    // 小说 / 文本 / PDF / 有声书 / 游戏域已随 ticket 04 移除。
    importEpub: (String filePath) async => null,
    importText: (String filePath) async => null,
    importPdf: (String filePath) async => null,
    importAudiobook: (AlignAudiobookPlan plan) async => null,
    importSubtitleAudiobook: (SubtitleAudiobookPlan plan) async => null,
    transcribeAudiobook: (TranscribeAudiobookPlan plan) async =>
        const DiscoveryImportOutcome(),
    importMangaArchive: (String archivePath) =>
        importDiscoveryMangaArchive(db, archivePath),
    registerGameExes: (List<String> exePaths) async => 0,
  );
}
