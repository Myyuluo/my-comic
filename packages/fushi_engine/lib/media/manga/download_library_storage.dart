/// Download library 的磁盘布局与 `pages.json`（storage-layout ADR 0012，票 04）。
///
/// 在线下载章节住在 Content root 的 Download library 里：
///
/// ```
/// downloads/
///   {source}/                    # Source 显示名（基础 Windows 净化）
///     {manga}/                   # 漫画标题（基础 Windows 净化）
///       .staging/{jobId}/        # 下载中的半成品；扫描/重建必须忽略
///       {chapter}/               # 完成后整章 rename 到这里
///         001.jpg                # 页图平铺、零填充
///         002.png
///         pages.json             # 稳定身份 + 页表 + 下载时间
/// ```
///
/// 目录名**不是身份**：数据库保存 `bookKey + chapterKey → folderName` 映射
/// （见 `manga_chapter_dirs`），标题/源改名不自动重命名目录。
///
/// `pages.json` 的页表复用 `manga.json` 的 `pages[{url,width,height,blocks}]`
/// 形状，因此阅读器/OCR 消费方不需要新的 payload 类型；`url` 是相对章目录的
/// 文件名（不带 `images/` 前缀）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/utils/misc/safe_file_name.dart';

/// Content root 下 Download library 的目录名。
const String kDownloadLibraryDirName = 'downloads';

/// 章节元数据文件名（与 `manga.json` 分开：布局不同、身份不同）。
const String kDownloadPagesFileName = 'pages.json';

/// Download library 里正在下载的章节目录：`<manga>/.staging/<jobId>`。
///
/// 点号开头 + 固定名字：重建/扫描按「点号目录不进入」忽略它，半成品永远
/// 不会出现在已下载索引里。
const String kDownloadStagingDirName = '.staging';

/// `pages.json` 的 schema 版本。
const int kDownloadPagesVersion = 1;

/// 当前实现支持识别的页图扩展名（按魔数判，非扩展名信任）。
const List<String> kDownloadPageExtensions = <String>[
  '.jpg',
  '.png',
  '.webp',
  '.gif',
];

/// 把一个任意的 source / manga / chapter 展示名净化成**基础**可用的 Windows
/// 目录名。
///
/// 票 04 只做基础净化：非法字符替换为 `_`、去掉结尾空格/点、空串退化为 `_`。
/// 保留设备名（CON/NUL…）、大小写冲突、超长截断、同名后缀（`[扫译组]` / `(2)`）
/// 属于票 05，这里刻意不做，免得两套规则漂移。
String sanitizeDownloadLibrarySegment(String raw) {
  String name = safeWindowsFileName(raw).trim();
  while (name.isNotEmpty && (name.endsWith('.') || name.endsWith(' '))) {
    name = name.substring(0, name.length - 1);
  }
  if (name.isEmpty) return '_';
  return name;
}

/// `<downloadsRoot>/<source>/<manga>`（不创建目录）。
Directory downloadMangaDirectory({
  required String downloadsRoot,
  required String sourceName,
  required String mangaTitle,
}) =>
    Directory(
      p.join(
        downloadsRoot,
        sanitizeDownloadLibrarySegment(sourceName),
        sanitizeDownloadLibrarySegment(mangaTitle),
      ),
    );

/// `<mangaDir>/.staging/<jobId>`（不创建目录）。
Directory downloadStagingDirectory(String mangaDir, String jobId) =>
    Directory(p.join(mangaDir, kDownloadStagingDirName, jobId));

/// 一个章目录 `<mangaDir>/<folderName>`（不创建目录）。
Directory downloadChapterDirectory(String mangaDir, String folderName) =>
    Directory(p.join(mangaDir, folderName));

/// 章元数据文件 `<chapterDir>/pages.json`。
File downloadPagesManifestFile(Directory chapterDir) =>
    File(p.join(chapterDir.path, kDownloadPagesFileName));

/// 页图文件名：零填充三位（`001.jpg`）。超过 999 页时自然变成 `1000.jpg`，
/// 字典序仍然正确。
String downloadPageFileName(int index, String extension) =>
    '${(index + 1).toString().padLeft(3, '0')}$extension';

/// 从页图字节的魔数取扩展名；未知格式按 `.jpg`（与旧下载行为一致）。
String downloadPageExtensionFor(List<int> bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return '.png';
  }
  if (bytes.length >= 12 &&
      String.fromCharCodes(bytes.skip(8).take(4)) == 'WEBP') {
    return '.webp';
  }
  if (bytes.length >= 6 &&
      (String.fromCharCodes(bytes.take(6)) == 'GIF89a' ||
          String.fromCharCodes(bytes.take(6)) == 'GIF87a')) {
    return '.gif';
  }
  return '.jpg';
}

/// `pages.json` 的稳定身份 + 页表。
///
/// Source/Manga/Chapter 的 ID 用来在目录被手工改名/移动后重新关联（Rebuild
/// download index）；目录名只用于人眼查找。
class MangaPagesManifest {
  const MangaPagesManifest({
    required this.sourceRuntime,
    required this.sourceId,
    required this.sourceName,
    required this.extensionPackage,
    required this.mangaKey,
    required this.mangaTitle,
    required this.chapterKey,
    required this.chapterName,
    required this.payload,
    required this.downloadedAt,
    this.chapterNumber,
    this.scanlator,
    this.chapterUrl,
  });

  final String sourceRuntime;
  final String sourceId;
  final String sourceName;
  final String extensionPackage;
  final String mangaKey;
  final String mangaTitle;
  final String chapterKey;
  final String chapterName;
  final double? chapterNumber;
  final String? scanlator;
  final String? chapterUrl;
  final MokuroPayload payload;
  final DateTime downloadedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'version': kDownloadPagesVersion,
        'source': <String, Object?>{
          'runtime': sourceRuntime,
          'id': sourceId,
          'name': sourceName,
          'extensionPackage': extensionPackage,
        },
        'manga': <String, Object?>{'key': mangaKey, 'title': mangaTitle},
        'chapter': <String, Object?>{
          'key': chapterKey,
          'name': chapterName,
          if (chapterNumber != null) 'number': chapterNumber,
          if (scanlator != null && scanlator!.isNotEmpty)
            'scanlator': scanlator,
          if (chapterUrl != null && chapterUrl!.isNotEmpty) 'url': chapterUrl,
        },
        'pages': mangaPayloadToJson(payload)['pages'],
        'downloadedAt': downloadedAt.toUtc().toIso8601String(),
      };

  /// 从 `pages.json` 文本解析；形状不合法返回 null（调用方按未下载处理）。
  static MangaPagesManifest? tryParse(String jsonStr) {
    Object? decoded;
    try {
      decoded = jsonDecode(jsonStr);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<Object?, Object?>) return null;
    final Map<String, Object?> json = decoded.cast<String, Object?>();
    final Object? rawSource = json['source'];
    final Object? rawManga = json['manga'];
    final Object? rawChapter = json['chapter'];
    if (rawSource is! Map<Object?, Object?> ||
        rawManga is! Map<Object?, Object?> ||
        rawChapter is! Map<Object?, Object?>) {
      return null;
    }
    final Map<String, Object?> source = rawSource.cast<String, Object?>();
    final Map<String, Object?> manga = rawManga.cast<String, Object?>();
    final Map<String, Object?> chapter = rawChapter.cast<String, Object?>();
    final String sourceId = source['id']?.toString() ?? '';
    final String mangaKey = manga['key']?.toString() ?? '';
    final String chapterKey = chapter['key']?.toString() ?? '';
    if (sourceId.isEmpty || mangaKey.isEmpty || chapterKey.isEmpty) return null;
    final DateTime? downloadedAt = DateTime.tryParse(
      json['downloadedAt']?.toString() ?? '',
    );
    if (downloadedAt == null) return null;
    return MangaPagesManifest(
      sourceRuntime: source['runtime']?.toString() ?? '',
      sourceId: sourceId,
      sourceName: source['name']?.toString() ?? '',
      extensionPackage: source['extensionPackage']?.toString() ?? '',
      mangaKey: mangaKey,
      mangaTitle: manga['title']?.toString() ?? '',
      chapterKey: chapterKey,
      chapterName: chapter['name']?.toString() ?? '',
      chapterNumber: (chapter['number'] as num?)?.toDouble(),
      scanlator: chapter['scanlator']?.toString(),
      chapterUrl: chapter['url']?.toString(),
      payload: parseMangaJson(jsonStr),
      downloadedAt: downloadedAt,
    );
  }
}

/// 原子写入 `pages.json`：先写同目录 `.tmp` 再 rename 覆盖。
///
/// 页图先落、`pages.json` 最后写，因此「只有 pages.json 完整」就意味着整章页图
/// 已经齐了；半截 JSON 永远不会被当成已下载。
Future<void> writePagesManifestAtomically(
  Directory chapterDir,
  MangaPagesManifest manifest,
) async {
  final File target = downloadPagesManifestFile(chapterDir);
  final File temporary = File('${target.path}.tmp');
  await temporary.writeAsString(jsonEncode(manifest.toJson()), flush: true);
  await temporary.rename(target.path);
}

/// 读取并校验 `pages.json`；文件不存在/JSON 损坏/缺稳定身份 → null。
Future<MangaPagesManifest?> readPagesManifest(Directory chapterDir) async {
  final File file = downloadPagesManifestFile(chapterDir);
  if (!await file.exists()) return null;
  try {
    return MangaPagesManifest.tryParse(await file.readAsString());
  } on Object {
    return null;
  }
}

/// 一章是否**完整**下载：`pages.json` 可解析、页表非空、每个页文件都在章目录内。
Future<bool> isDownloadLibraryChapterComplete(Directory chapterDir) async =>
    await readDownloadLibraryChapterPayload(chapterDir) != null;

/// 读取已下载章的页表；任一条件不满足返回 null。
///
/// 判据与阅读器/作品页/重建共用这一处：只看 `pages.json` 会把「页图没下完」
/// 当成已下载，只看目录非空会把半成品当已下载。
Future<MokuroPayload?> readDownloadLibraryChapterPayload(
  Directory chapterDir,
) async {
  final MangaPagesManifest? manifest = await readPagesManifest(chapterDir);
  if (manifest == null) return null;
  if (manifest.payload.images.isEmpty) return null;
  final String root = p.canonicalize(chapterDir.path);
  for (final MokuroImage image in manifest.payload.images) {
    final String relative = normalizeMangaUrl(image.url);
    if (relative.isEmpty) return null;
    final String candidate = p.canonicalize(p.join(root, relative));
    if (!p.isWithin(root, candidate)) return null;
    if (FileSystemEntity.typeSync(candidate) != FileSystemEntityType.file) {
      return null;
    }
  }
  return manifest.payload;
}
