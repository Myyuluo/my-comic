/// 在线漫画的统一下载身份。
///
/// 身份核心是 `(runtime, 数字 sourceId, seriesKey/mangaKey)`：`pages.json`、
/// 下载服务认领、文件夹复用与 Rebuild download index 必须用同一份判据，避免
/// 三处各写一遍后对占位扩展包 / 数字 sourceId 的容忍度不一致。
///
/// 扩展包只做 tie-breaker：同为真实包且相等才加分；`mihon.unavailable`
/// （导入时来源未安装的占位）与空扩展包（旧描述符没记录）视为兼容。
library;

import 'package:fushi_engine/media/manga/download_library_storage.dart';

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';

/// source id 的规范形式：纯十进制按数值归一（`001` 与 `1` 相同），
/// 非数字（互联 / Local 等）按去空白后的原字符串比较。
String downloadSourceIdKey(String sourceId) {
  final String trimmed = sourceId.trim();
  return normalizedMangaSourceId(trimmed) ?? trimmed;
}

/// 两个扩展包是否能证明是同一个来源。
///
/// - 相等（含都为空）→ 兼容；
/// - 任一侧为空（旧描述符没记录包）→ 无法区分，兼容；
/// - 任一侧是 [kUnavailableMihonExtensionPackage] → 占位身份，兼容；
/// - 两个不同的真实包 → 不兼容。
bool downloadExtensionPackagesCompatible(String a, String b) {
  final String left = a.trim();
  final String right = b.trim();
  if (left == right) return true;
  if (left.isEmpty || right.isEmpty) return true;
  return left == kUnavailableMihonExtensionPackage ||
      right == kUnavailableMihonExtensionPackage;
}

/// 一部在线漫画的下载身份。
class MangaDownloadIdentity {
  const MangaDownloadIdentity({
    required this.runtime,
    required this.extensionPackage,
    required this.sourceId,
    required this.seriesKey,
  });

  factory MangaDownloadIdentity.ofEntry(OnlineMangaLibraryEntry entry) =>
      MangaDownloadIdentity(
        runtime: entry.runtime,
        extensionPackage: entry.extensionPackage,
        sourceId: entry.sourceId,
        seriesKey: entry.series.key,
      );

  final OnlineMangaRuntimeKind runtime;
  final String extensionPackage;
  final String sourceId;
  final String seriesKey;

  String get sourceIdKey => downloadSourceIdKey(sourceId);

  /// [manifest] 是否证明自己属于这部作品（不含章节）。
  bool matchesManifest(MangaPagesManifest manifest) {
    if (manifest.sourceRuntime != runtime.wireValue) return false;
    if (manifest.mangaKey != seriesKey) return false;
    if (downloadSourceIdKey(manifest.sourceId) != sourceIdKey) return false;
    return downloadExtensionPackagesCompatible(
      manifest.extensionPackage,
      extensionPackage,
    );
  }

  /// tie-breaker：manifest 带的是与条目相同的**真实**扩展包。
  ///
  /// 占位包不算精确命中——否则占位条目会把「同为占位」的旧 manifest 当成
  /// 唯一匹配，而不是继续把真实包的文件夹纳入候选。
  bool matchesManifestPackage(MangaPagesManifest manifest) {
    final String manifestPackage = manifest.extensionPackage.trim();
    final String entryPackage = extensionPackage.trim();
    if (manifestPackage.isEmpty || entryPackage.isEmpty) return false;
    if (manifestPackage == kUnavailableMihonExtensionPackage ||
        entryPackage == kUnavailableMihonExtensionPackage) {
      return false;
    }
    return manifestPackage == entryPackage;
  }
}

/// 一个 Source 的下载身份（不含 Manga）：`runtime + 数字 sourceId`，
/// 扩展包兼容规则同 [downloadExtensionPackagesCompatible]。
///
/// 用于 `downloads/<source>` 目录归属：来源改名不应换目录，占位包与真实包
/// 也不能把同一来源拆成两个目录。
class DownloadSourceIdentity {
  const DownloadSourceIdentity({
    required this.runtimeWire,
    required this.extensionPackage,
    required this.sourceId,
  });

  factory DownloadSourceIdentity.fromEntry(OnlineMangaLibraryEntry entry) =>
      DownloadSourceIdentity(
        runtimeWire: entry.runtime.wireValue,
        extensionPackage: entry.extensionPackage,
        sourceId: entry.sourceId,
      );

  factory DownloadSourceIdentity.fromManifest(MangaPagesManifest manifest) =>
      DownloadSourceIdentity(
        runtimeWire: manifest.sourceRuntime,
        extensionPackage: manifest.extensionPackage,
        sourceId: manifest.sourceId,
      );

  final String runtimeWire;
  final String extensionPackage;
  final String sourceId;

  String get sourceIdKey => downloadSourceIdKey(sourceId);

  bool matches(DownloadSourceIdentity other) =>
      runtimeWire == other.runtimeWire &&
      sourceIdKey == other.sourceIdKey &&
      downloadExtensionPackagesCompatible(
        extensionPackage,
        other.extensionPackage,
      );

  bool matchesEntry(OnlineMangaLibraryEntry entry) =>
      matches(DownloadSourceIdentity.fromEntry(entry));

  @override
  bool operator ==(Object other) =>
      other is DownloadSourceIdentity &&
      other.runtimeWire == runtimeWire &&
      other.sourceIdKey == sourceIdKey &&
      other.extensionPackage == extensionPackage;

  @override
  int get hashCode => Object.hash(runtimeWire, sourceIdKey, extensionPackage);
}
