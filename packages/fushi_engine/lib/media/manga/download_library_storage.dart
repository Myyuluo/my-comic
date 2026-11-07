/// Download library 的磁盘布局与 `pages.json`（storage-layout ADR 0012，票 04）。
///
/// 在线下载章节住在 Content root 的 Download library 里：
///
/// ```
/// downloads/
///   {source}/                    # Source 显示名（基础 Windows 净化）
///     {manga}/                   # 漫画标题（基础 Windows 净化）
///       .staging/{jobId}/        # 下载中的半成品；扫描/重建必须忽略
///       {chapter}/               # 文件夹章节：完成后整章 rename 到这里
///         001.jpg                # 页图平铺、零填充
///         002.png
///         pages.json             # 稳定身份 + 页表 + 下载时间
///       {chapter}.cbz            # CBZ 章节（ticket 08 起新下载默认）：
///                                # 包根同样是 001.jpg… + pages.json
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

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/manga/local_source/local_source_archive.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/utils/archive/native_zip.dart';
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

/// 单个目录段（source / manga / chapter）的最大长度。
///
/// 远小于 NTFS 的 255：段本身再叠加 `(2)`/`[扫译组]` 后缀后仍然安全，也给
/// 完整路径预算留出余量。
const int kDownloadLibraryMaxSegmentLength = 96;

/// Download library 章节路径的目标上限（Windows 传统 MAX_PATH 是 260）。
const int kDownloadLibraryMaxPathLength = 240;

/// 为 `<manga>/.staging/<jobId>/<page>.tmp` 预留的路径长度。
///
/// 下载先写 staging 再整章 rename；staging 比正式章目录多出 `.staging/` 与
/// 32 位 jobId，manga 目录太长时 staging 页路径会先撞上 MAX_PATH。
const int kDownloadLibraryStagingPathReserve = 56;

/// 给子目录预留的最小名字预算（只用于 source/manga 的路径预算分配）。
const int kDownloadLibraryMinChildPathBudget = 16;

/// 把一个任意的 source / manga / chapter 展示名净化成可用的 Windows 目录名。
///
/// 规则（票 04 基础 + 票 05 边界）：
/// - Windows 非法字符逐个替换为 `_`；
/// - 去掉首尾空白、结尾的点与空格；
/// - 空串（或只剩点/空格）退化为 `_`；
/// - 保留设备名（`CON`/`NUL`/`COM1`…）前缀 `_`；
/// - 超过 [maxLength] 时截断并追加 `~<8 位内容哈希>`，保证确定且不同全名不撞。
///
/// 大小写冲突、同名后缀（`[扫译组]` / `(2)`）需要看磁盘/数据库里已有什么，
/// 由调用方用 [uniqueDownloadLibraryFolderName] 解决，不在纯净化里猜。
String sanitizeDownloadLibrarySegment(
  String raw, {
  int maxLength = kDownloadLibraryMaxSegmentLength,
}) {
  String name = safeWindowsFileName(raw).trim();
  while (name.isNotEmpty && (name.endsWith('.') || name.endsWith(' '))) {
    name = name.substring(0, name.length - 1);
  }
  if (name.isEmpty) return '_';
  // 点号开头的目录会被扫描/重建忽略（`.staging` 同规则）；用户内容不能躲进去。
  if (name.startsWith('.')) name = '_$name';
  if (isWindowsReservedFileName(name)) name = '_$name';
  return _truncateDownloadLibrarySegment(name, maxLength);
}

/// 截断到 [maxLength]，保留尾部 `~<8 位哈希>` 以便区分共享前缀的长名字。
String _truncateDownloadLibrarySegment(String name, int maxLength) {
  if (maxLength <= 0 || name.length <= maxLength) return name;
  final String hash = sha256.convert(utf8.encode(name)).toString();
  final String suffix = '~${hash.substring(0, 8)}';
  if (maxLength <= suffix.length) return suffix;
  int cut = maxLength - suffix.length;
  // 不把 UTF-16 代理对切成两半（Windows 文件名长度按 UTF-16 计）。
  final int last = name.codeUnitAt(cut - 1);
  if (last >= 0xD800 && last <= 0xDBFF && cut > 1) cut -= 1;
  final String stem = name
      .substring(0, cut)
      .replaceFirst(RegExp(r'[ .]+$'), '');
  return '$stem$suffix';
}

/// 在 [parentPath] 下再放一个目录时，该目录名允许的最大长度。
///
/// [pathReserve] 是留给后续子路径（如 `.staging/<jobId>/<page>`）的长度。
/// 父路径本身已经很长时返回不小于 1 的值；此时只能保证段合法，无法保证
/// 完整路径仍在上限内（Content root 极端深的情况）。
int downloadLibrarySegmentBudget(
  String parentPath, {
  int pathReserve = 0,
}) {
  final int available =
      kDownloadLibraryMaxPathLength - parentPath.length - 1 - pathReserve;
  if (available < 1) return 1;
  return available < kDownloadLibraryMaxSegmentLength
      ? available
      : kDownloadLibraryMaxSegmentLength;
}

/// Source 目录段名（未处理同名冲突；冲突由调用方加后缀）。
String downloadSourceFolderName({
  required String downloadsRoot,
  required String sourceName,
}) => sanitizeDownloadLibrarySegment(
  sourceName,
  maxLength: downloadLibrarySegmentBudget(
    downloadsRoot,
    pathReserve:
        1 +
        kDownloadLibraryStagingPathReserve +
        kDownloadLibraryMinChildPathBudget,
  ),
);

/// Manga 目录段名（未处理同名冲突；冲突由调用方加后缀）。
String downloadMangaFolderName({
  required String sourceDirPath,
  required String title,
}) => sanitizeDownloadLibrarySegment(
  title,
  maxLength: downloadLibrarySegmentBudget(
    sourceDirPath,
    pathReserve: kDownloadLibraryStagingPathReserve,
  ),
);

/// Chapter 目录段名（未处理同名冲突；冲突由调用方加后缀）。
String downloadChapterFolderName({
  required String mangaDirPath,
  required String raw,
}) => sanitizeDownloadLibrarySegment(
  raw,
  maxLength: downloadLibrarySegmentBudget(mangaDirPath),
);

/// `<downloadsRoot>/<source>`（不创建目录）。
Directory downloadSourceDirectory({
  required String downloadsRoot,
  required String sourceName,
  String? folderName,
}) => Directory(
  p.join(
    downloadsRoot,
    folderName ?? downloadSourceFolderName(
      downloadsRoot: downloadsRoot,
      sourceName: sourceName,
    ),
  ),
);

/// `<downloadsRoot>/<source>/<manga>`（不创建目录）。
///
/// [sourceFolderName] / [mangaFolderName] 允许调用方传入已经解决冲突（同名
/// Source、同名 Manga）的目录段；不传则按净化 + 路径预算派生。
Directory downloadMangaDirectory({
  required String downloadsRoot,
  required String sourceName,
  required String mangaTitle,
  String? sourceFolderName,
  String? mangaFolderName,
}) {
  final String sourceDirPath = downloadSourceDirectory(
    downloadsRoot: downloadsRoot,
    sourceName: sourceName,
    folderName: sourceFolderName,
  ).path;
  return Directory(
    p.join(
      sourceDirPath,
      mangaFolderName ?? downloadMangaFolderName(
        sourceDirPath: sourceDirPath,
        title: mangaTitle,
      ),
    ),
  );
}

/// 稳定身份的短哈希（8 位十六进制）：同名 Source 的目录后缀等。
String downloadLibraryShortHash(String value) =>
    sha256.convert(utf8.encode(value)).toString().substring(0, 8);

/// 在 [base] 后追加 [suffix]；超长时截断 base 并保留 `~<8 位哈希>` 与后缀。
String fitDownloadLibrarySegmentWithSuffix({
  required String base,
  required String suffix,
  int maxLength = kDownloadLibraryMaxSegmentLength,
}) {
  final String candidate = '$base$suffix';
  if (maxLength <= 0 || candidate.length <= maxLength) return candidate;
  final String hash = sha256.convert(utf8.encode(base)).toString();
  final String tail = '~${hash.substring(0, 8)}$suffix';
  if (maxLength <= tail.length) return candidate;
  int cut = maxLength - tail.length;
  if (cut > 1) {
    final int last = base.codeUnitAt(cut - 1);
    if (last >= 0xD800 && last <= 0xDBFF) cut -= 1;
  }
  final String stem = base
      .substring(0, cut)
      .replaceFirst(RegExp(r'[ .]+$'), '');
  return '$stem$tail';
}

/// 取第一个未被占用的目录名。
///
/// 首选 [base]；被占时若有 [qualifier]（扫译组）先试 `base [qualifier]`，
/// 再退到 `base [qualifier] (2)…` / `base (2)…`。比较是否占用由 [isTaken]
/// 决定（调用方负责大小写不敏感）。
Future<String> uniqueDownloadLibraryFolderName({
  required String base,
  String? qualifier,
  required Future<bool> Function(String candidate) isTaken,
  int maxLength = kDownloadLibraryMaxSegmentLength,
}) async {
  if (!await isTaken(base)) return base;
  final String preferred = qualifier == null || qualifier.isEmpty
      ? base
      : fitDownloadLibrarySegmentWithSuffix(
          base: base,
          suffix: ' [$qualifier]',
          maxLength: maxLength,
        );
  if (preferred != base && !await isTaken(preferred)) return preferred;
  for (int index = 2; ; index++) {
    final String candidate = fitDownloadLibrarySegmentWithSuffix(
      base: preferred,
      suffix: ' ($index)',
      maxLength: maxLength,
    );
    if (!await isTaken(candidate)) return candidate;
  }
}

/// `<mangaDir>/.staging/<jobId>`（不创建目录）。
Directory downloadStagingDirectory(String mangaDir, String jobId) =>
    Directory(p.join(mangaDir, kDownloadStagingDirName, jobId));

/// 一个章目录 `<mangaDir>/<folderName>`（不创建目录）。
Directory downloadChapterDirectory(String mangaDir, String folderName) =>
    Directory(p.join(mangaDir, folderName));

/// CBZ 章节容器的扩展名（比较前统一小写）。
const String kDownloadArchiveExtension = '.cbz';

/// [name]（单段容器名）是否表示一个 CBZ 压缩包。
bool isDownloadChapterArchiveName(String name) =>
    p.extension(name).toLowerCase() == kDownloadArchiveExtension;

/// 规范压缩包容器名：纯章名补 `.cbz`，已带扩展名原样返回。
///
/// 数据库 `manga_chapter_dirs.folder_name` 对 archive 存的是**含扩展名的
/// 完整文件名**，因此下载写入与重建扫描用同一口径。
String downloadChapterArchiveName(String raw) {
  final String trimmed = raw.trim();
  return isDownloadChapterArchiveName(trimmed)
      ? trimmed
      : '$trimmed$kDownloadArchiveExtension';
}

/// 一个 CBZ 章节容器 `<mangaDir>/<containerName>`（不创建文件）。
File downloadChapterArchiveFile(String mangaDir, String containerName) =>
    File(p.join(mangaDir, containerName));

/// 选一个未占用的 CBZ 章节容器名（含 `.cbz`）。
///
/// 与文件夹命名共用同一套冲突消解：净化 [base]（长度预算先减去扩展名）后按
/// `[扫译组]` / `(2)` 递增；[isTaken] 收到的候选名**已带扩展名**，调用方按
/// 完整文件名（大小写不敏感）判断占用。
Future<String> uniqueDownloadChapterArchiveName({
  required String mangaDir,
  required String base,
  String? qualifier,
  required Future<bool> Function(String name) isTaken,
}) async {
  final int budget = downloadLibrarySegmentBudget(mangaDir);
  final int baseBudget = budget > kDownloadArchiveExtension.length
      ? budget - kDownloadArchiveExtension.length
      : 1;
  final String unique = await uniqueDownloadLibraryFolderName(
    base: sanitizeDownloadLibrarySegment(base, maxLength: baseBudget),
    qualifier: qualifier,
    isTaken: (String candidate) =>
        isTaken(downloadChapterArchiveName(candidate)),
    maxLength: baseBudget,
  );
  return downloadChapterArchiveName(unique);
}

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

// ── CBZ 章节容器（票 06） ──────────────────────────────────────────────

/// 读取 CBZ 章节包根 `pages.json`；文件不存在 / 不是 ZIP / JSON 损坏 → null。
///
/// 只看中央目录 + 解压这一个条目，不把整包解压到磁盘。
Future<MangaPagesManifest?> readDownloadLibraryArchiveManifest(
  File archiveFile,
) async {
  if (!await archiveFile.exists()) return null;
  final LocalSourceArchive archive;
  try {
    archive = LocalSourceArchive.open(archiveFile.path);
  } on Object {
    return null;
  }
  try {
    final List<int>? bytes = archive.readEntry(kDownloadPagesFileName);
    if (bytes == null) return null;
    return MangaPagesManifest.tryParse(utf8.decode(bytes));
  } on Object {
    return null;
  } finally {
    archive.close();
  }
}

/// 一个 CBZ 章节是否**完整**：包根 `pages.json` 可解析、页表非空、每页条目
/// 都在包里。判据与文件夹章节的 [readDownloadLibraryChapterPayload] 同口径。
Future<MokuroPayload?> readDownloadLibraryArchivePayload(
  File archiveFile,
) async {
  final MangaPagesManifest? manifest = await readDownloadLibraryArchiveManifest(
    archiveFile,
  );
  if (manifest == null) return null;
  if (manifest.payload.images.isEmpty) return null;
  final LocalSourceArchive archive;
  try {
    archive = LocalSourceArchive.open(archiveFile.path);
  } on Object {
    return null;
  }
  try {
    final Set<String> exact = <String>{
      for (final LocalSourceArchiveEntry entry in archive.entries) entry.name,
    };
    final Set<String> folded = <String>{
      for (final LocalSourceArchiveEntry entry in archive.entries)
        entry.name.toLowerCase(),
    };
    for (final MokuroImage image in manifest.payload.images) {
      final String relative = normalizeMangaUrl(image.url);
      final List<String> segments = relative
          .split('/')
          .where((String segment) => segment.isNotEmpty && segment != '.')
          .toList();
      if (segments.isEmpty ||
          segments.any((String segment) => segment == '..')) {
        return null;
      }
      final String name = segments.join('/');
      if (!exact.contains(name) && !folded.contains(name.toLowerCase())) {
        return null;
      }
    }
    return manifest.payload;
  } on Object {
    return null;
  } finally {
    archive.close();
  }
}

/// 一章（CBZ 容器）是否完整下载。
Future<bool> isDownloadLibraryArchiveComplete(File archiveFile) async =>
    await readDownloadLibraryArchivePayload(archiveFile) != null;

/// 把 staging 里的平铺页图与 `pages.json` 写成 CBZ 的**临时**包。
///
/// 只收 staging 根下的常规文件：跳过点号文件与 `.tmp`（页图先写 `.tmp` 再改名，
/// 崩溃可能留下半截页）；`pages.json` 最后写入包内。调用方负责把内容写到同一
/// 漫画目录的 `{chapter}.cbz.tmp`，完成后原子改名为最终 `.cbz`——半成品永远不会
/// 以 `.cbz` 出现。
Future<void> writeDownloadChapterArchive({
  required Directory staging,
  required File temporaryArchive,
}) async {
  final List<File> pages = <File>[];
  File? manifest;
  await for (final FileSystemEntity entity in staging.list(followLinks: false)) {
    if (entity is! File) continue;
    final String name = p.basename(entity.path);
    if (name.startsWith('.') || name.toLowerCase().endsWith('.tmp')) continue;
    if (name == kDownloadPagesFileName) {
      manifest = entity;
      continue;
    }
    pages.add(entity);
  }
  pages.sort(
    (File a, File b) => p.basename(a.path).compareTo(p.basename(b.path)),
  );
  final File? manifestFile = manifest;
  if (manifestFile == null) {
    throw StateError(
      'Cannot write a CBZ without $kDownloadPagesFileName in staging',
    );
  }
  final ZipFileEncoder encoder = ZipFileEncoder();
  encoder.create(temporaryArchive.path);
  try {
    for (final File page in pages) {
      // 原生 zlib 分块压缩；页图（jpg/png/…）按 STORE 直写，不二次压缩。
      addFileNativeDeflate(encoder, page, p.basename(page.path));
    }
    addFileNativeDeflate(encoder, manifestFile, kDownloadPagesFileName);
  } finally {
    await encoder.close();
  }
}
