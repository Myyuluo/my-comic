/// Local source root（ADR 0013）的目录扫描与章节识别。
///
/// `local/{manga}/{chapter}/` 是 Mihon local-source layout：
/// - 第一层目录 = 一部 Manga；
/// - Manga 目录下的每个含页图的直接子目录 = 一个 Chapter；
/// - Manga 目录下的每个 `.cbz` 文件 = 一个 CBZ Chapter（包根 `pages.json`
///   优先，缺失/损坏时回退图片扫描）；
/// - Manga 目录**直接**含页图时，整本目录算单章（不再拆子目录、不看 CBZ）；
/// - `cover.jpg`（也接受 jpeg/png）只作封面，不算页；
/// - 章节目录 / CBZ 里可选的 `pages.json` 决定页序；缺失、损坏或缺页时回退到
///   按自然序扫描图片。
///
/// 扫描只读文件系统，不写任何文件——Local source 原地读取、不复制（ADR 0013）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:my_comic_engine/media/manga/shelf_sort.dart'
    show naturalCompare;
import 'package:my_comic_engine/media/manga/local_source/local_source_archive.dart';
import 'package:my_comic_engine/media/manga/manga_importer.dart'
    show kMangaImageExtensions;
import 'package:my_comic_engine/media/manga/page_enumeration.dart';

/// 章节目录内可选的页表文件名（与 Download library 的 `pages.json` 同名）。
const String kLocalSourcePagesJsonFileName = 'pages.json';

/// 被识作封面的文件名（小写）。与既有封面解析器
/// `ReaderMyComicSource.resolveCoverFilePath` 的候选一致。
const Set<String> kLocalSourceCoverFileNames = <String>{
  'cover.jpg',
  'cover.jpeg',
  'cover.png',
};

/// 单章（manga 目录直接含页图）的章节 key。真实子目录名不可能等于 `.`。
const String kLocalSourceRootChapterKey = '.';

/// 章节容器的形态。
enum LocalSourceChapterKind {
  /// `{chapter}/` 文件夹（页图平铺或分卷子目录）。
  folder,

  /// `{chapter}.cbz` 压缩包。
  archive,
}

/// 一张页图：磁盘文件 + 相对章节目录的正斜杠路径。
///
/// CBZ 章节的页在压缩包里，没有独立磁盘文件（[file] 为 null）；阅读时按
/// [relativePath]（包内条目名）按需从包里取。
class LocalSourcePage {
  const LocalSourcePage({
    this.file,
    required this.relativePath,
    this.width,
    this.height,
  });

  /// 文件夹章节的页文件；CBZ 章节为 null。
  final File? file;

  /// 相对章节目录的正斜杠路径（`001.jpg` / `vol1/001.jpg`）；CBZ 章节为
  /// 包内归一化条目名。
  final String relativePath;

  /// `pages.json` 声明的宽高；扫描回退时未知（阅读器按文件头探测）。
  final int? width;
  final int? height;
}

/// 一个章节：文件夹或 CBZ。
class LocalSourceChapter {
  const LocalSourceChapter({
    required this.key,
    required this.name,
    required this.relativePath,
    required this.pages,
    this.kind = LocalSourceChapterKind.folder,
    this.archiveFile,
  });

  /// 章节身份 = 相对 Manga 目录的路径（单章为 [kLocalSourceRootChapterKey]）。
  /// 目录/文件改名或移动 = 新 key（ADR 0013：作品身份按文件夹路径认）。
  final String key;

  /// 展示名（章节目录名 / CBZ 去掉扩展名的文件名；单章为 Manga 目录名）。
  final String name;

  /// 相对 Manga 目录的正斜杠路径；单章为空串。
  final String relativePath;

  final List<LocalSourcePage> pages;

  final LocalSourceChapterKind kind;

  /// CBZ 章节的压缩包文件；文件夹章节为 null。
  final File? archiveFile;

  bool get isArchive => kind == LocalSourceChapterKind.archive;
  bool get isRootChapter => relativePath.isEmpty;
}

/// 一部本地漫画：第一层目录。
class LocalSourceManga {
  const LocalSourceManga({
    required this.title,
    required this.directoryPath,
    required this.relativePath,
    required this.chapters,
    required this.coverRelativePath,
  });

  /// 展示标题 = Manga 目录名。
  final String title;

  /// Manga 目录绝对路径（原地读取）。
  final String directoryPath;

  /// 相对 Local source root 的正斜杠路径（用于重启后重新定位）。
  final String relativePath;

  /// 直接子目录章节，按自然序。
  final List<LocalSourceChapter> chapters;

  /// `cover.jpg/jpeg/png` 相对 Manga 目录的路径；没有为 null。
  final String? coverRelativePath;

  int get pageCount => chapters.fold<int>(
    0,
    (int sum, LocalSourceChapter c) => sum + c.pages.length,
  );
}

/// [path] 是否等于 [root] 或位于 [root] 之下（Local source 原地读取的边界）。
///
/// 路径比较先规范化（Windows 大小写不敏感由 package:path 的平台语义负责）。
/// 用途：切换 Content root 后，库里记录的旧作品目录不再是当前 Local source root
/// 的一部分——读取入口据此拒绝回读旧路径，把作品当作 Missing。
bool isLocalSourcePathWithinRoot(String path, Directory root) {
  final String canonicalRoot = p.canonicalize(root.path);
  final String canonicalPath = p.canonicalize(path);
  return p.equals(canonicalRoot, canonicalPath) ||
      p.isWithin(canonicalRoot, canonicalPath);
}

/// 一部 Local source 作品的封面相对路径：优先 `cover.jpg/jpeg/png`，否则取第一
/// 个文件夹章节的首页。
///
/// CBZ 章节的页没有独立磁盘文件（封面解析只认真实文件），跳过——`cover.jpg`
/// 约定仍由封面解析器在作品目录里兜底。登记（[LocalSourceLibrary]）与重建
/// （Rebuild download index）共用这一处，避免两边对「哪张图算封面」漂移。
String? localSourceCoverRelativePath(LocalSourceManga manga) {
  if (manga.coverRelativePath != null) return manga.coverRelativePath;
  for (final LocalSourceChapter chapter in manga.chapters) {
    if (chapter.isArchive) continue;
    if (chapter.pages.isEmpty) continue;
    final String page = chapter.pages.first.relativePath;
    return chapter.relativePath.isEmpty
        ? page
        : '${chapter.relativePath}/$page';
  }
  return null;
}

/// 扫描 Local source root 的**第一层目录**为作品。
///
/// 不递归到更深层找作品；根下散落的文件、点目录（`.staging` 等）忽略。没有页图
/// 的目录（只有封面 / 空目录）不算作品。目录读取失败按空处理，不让一次扫描整体
/// 失败。
Future<List<LocalSourceManga>> scanLocalSourceRoot(Directory root) async {
  if (!await root.exists()) return const <LocalSourceManga>[];
  final List<Directory> mangaDirs = <Directory>[];
  try {
    for (final FileSystemEntity entity in root.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final String name = p.basename(entity.path);
      if (name.startsWith('.') || name == 'Thumbs.db') continue;
      mangaDirs.add(entity);
    }
  } on FileSystemException {
    return const <LocalSourceManga>[];
  }
  mangaDirs.sort(
    (Directory a, Directory b) =>
        naturalCompare(p.basename(a.path), p.basename(b.path)),
  );

  final List<LocalSourceManga> mangas = <LocalSourceManga>[];
  for (final Directory dir in mangaDirs) {
    try {
      final LocalSourceManga? manga = await _scanManga(root, dir);
      if (manga != null) mangas.add(manga);
    } on FileSystemException {
      // 单个作品读不了（权限 / 占用）：跳过它，其余作品照常回来。
    }
  }
  return mangas;
}

Future<LocalSourceManga?> _scanManga(Directory root, Directory mangaDir) =>
    scanLocalSourceMangaDirectory(
      mangaDir,
      relativePath: localSourceRelativePath(mangaDir.path, from: root.path),
    );

/// 扫描**单个** Manga 目录（第一层目录 = 章节 / CBZ；目录直接含页图 = 单章）。
///
/// [relativePath] 是这部作品相对调用方所认定根目录的正斜杠路径（用于
/// `LocalSourceMetadata` 的重新定位）；Local source root 扫描与 Rebuild download
/// index 的恢复分支共用这一处。只读，不写任何文件。
Future<LocalSourceManga?> scanLocalSourceMangaDirectory(
  Directory mangaDir, {
  required String relativePath,
}) async {
  final String title = p.basename(mangaDir.path);
  final String? cover = _findCover(mangaDir.path);
  final List<FileSystemEntity> entries = _list(mangaDir);

  final bool rootHasImages = entries.any(
    (FileSystemEntity e) =>
        e is File && _isPageImage(e.path) && !_isCoverFile(e.path),
  );

  final List<LocalSourceChapter> chapters = <LocalSourceChapter>[];
  if (rootHasImages) {
    final List<LocalSourcePage> pages = await readLocalSourceChapterPages(
      mangaDir.path,
      isRootChapter: true,
    );
    if (pages.isNotEmpty) {
      chapters.add(
        LocalSourceChapter(
          key: kLocalSourceRootChapterKey,
          name: title,
          relativePath: '',
          pages: pages,
        ),
      );
    }
  } else {
    final List<_ChapterSource> sources = <_ChapterSource>[];
    for (final FileSystemEntity entity in entries) {
      if (entity is Directory) {
        final String name = p.basename(entity.path);
        if (name.startsWith('.') || name == 'manga_ocr_out') continue;
        sources.add(
          _ChapterSource(
            name: name,
            relativePath: localSourceRelativePath(entity.path, from: mangaDir.path),
            directory: entity,
          ),
        );
      } else if (entity is File && _isCbzFile(entity.path)) {
        final String fileName = p.basename(entity.path);
        if (fileName.startsWith('.')) continue;
        sources.add(
          _ChapterSource(
            name: p.basenameWithoutExtension(fileName),
            relativePath: localSourceRelativePath(entity.path, from: mangaDir.path),
            archive: entity,
          ),
        );
      }
    }
    sources.sort((_ChapterSource a, _ChapterSource b) {
      final int byName = naturalCompare(a.name, b.name);
      if (byName != 0) return byName;
      return naturalCompare(a.relativePath, b.relativePath);
    });
    for (final _ChapterSource source in sources) {
      final List<LocalSourcePage> pages;
      try {
        if (source.archive != null) {
          pages = readLocalSourceArchiveChapterPages(source.archive!.path);
        } else {
          pages = await readLocalSourceChapterPages(
            source.directory!.path,
            isRootChapter: false,
          );
        }
      } on Object {
        // 坏包 / 读不了的章节目录：跳过这一章，其余章节照常回来。
        continue;
      }
      if (pages.isEmpty) continue;
      chapters.add(
        LocalSourceChapter(
          key: source.relativePath,
          name: source.name,
          relativePath: source.relativePath,
          pages: pages,
          kind: source.archive == null
              ? LocalSourceChapterKind.folder
              : LocalSourceChapterKind.archive,
          archiveFile: source.archive,
        ),
      );
    }
  }
  if (chapters.isEmpty) return null;
  return LocalSourceManga(
    title: title,
    directoryPath: mangaDir.path,
    relativePath: relativePath,
    chapters: List<LocalSourceChapter>.unmodifiable(chapters),
    coverRelativePath: cover,
  );
}

/// 章节目录的页列表：`pages.json` 优先，缺失/损坏/缺页回退图片扫描。
Future<List<LocalSourcePage>> readLocalSourceChapterPages(
  String chapterDirPath, {
  required bool isRootChapter,
}) async {
  final List<LocalSourcePage>? fromJson = await _readPagesJson(chapterDirPath);

  if (fromJson != null) return fromJson;

  final Directory chapterDir = Directory(chapterDirPath);
  final List<MangaOcrPageFile> scanned = enumerateMangaPages(chapterDir);
  final List<LocalSourcePage> pages = <LocalSourcePage>[];
  for (final MangaOcrPageFile page in scanned) {
    final String relative = page.relativeUrl;
    if (_hasDotSegment(relative)) continue;
    if (isRootChapter && _isCoverRelativePath(relative)) continue;
    pages.add(LocalSourcePage(file: page.file, relativePath: relative));
  }
  return pages;
}

/// CBZ 章节的页表：包根 `pages.json` 优先，缺失/损坏/缺页时回退图片扫描。
///
/// 打开、读完条目表即关闭，不把包内容解压到磁盘。
List<LocalSourcePage> readLocalSourceArchiveChapterPages(String archivePath) {
  final LocalSourceArchive archive = LocalSourceArchive.open(archivePath);
  try {
    return <LocalSourcePage>[
      for (final LocalSourceArchivePage page in readLocalSourceArchivePages(
        archive,
      ))
        LocalSourcePage(
          relativePath: page.relativePath,
          width: page.width,
          height: page.height,
        ),
    ];
  } finally {
    archive.close();
  }
}

/// 扫描时的一个章节候选：目录或 CBZ。
class _ChapterSource {
  const _ChapterSource({
    required this.name,
    required this.relativePath,
    this.directory,
    this.archive,
  });

  final String name;
  final String relativePath;
  final Directory? directory;
  final File? archive;
}

bool _isCbzFile(String path) => p.extension(path).toLowerCase() == '.cbz';

Future<List<LocalSourcePage>?> _readPagesJson(String chapterDirPath) async {
  final File jsonFile = File(
    p.join(chapterDirPath, kLocalSourcePagesJsonFileName),
  );
  if (!await jsonFile.exists()) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(await jsonFile.readAsString());
  } on Object {
    return null;
  }
  if (decoded is! Map<Object?, Object?>) return null;
  final Object? rawPages = decoded['pages'];
  if (rawPages is! List<Object?> || rawPages.isEmpty) return null;

  final List<LocalSourcePage> pages = <LocalSourcePage>[];
  final String chapterRoot = p.canonicalize(chapterDirPath);
  for (final Object? raw in rawPages) {
    if (raw is! Map<Object?, Object?>) return null;
    final String url = raw['url']?.toString().trim() ?? '';
    if (url.isEmpty) return null;
    final List<String> segments = url
        .replaceAll('\\', '/')
        .split('/')
        .where((String s) => s.isNotEmpty && s != '.')
        .toList();
    if (segments.isEmpty || segments.any((String s) => s == '..')) return null;
    final String candidate = p.canonicalize(
      p.joinAll(<String>[chapterDirPath, ...segments]),
    );
    if (!p.isWithin(chapterRoot, candidate)) return null;
    final File file = File(candidate);
    if (!await file.exists()) return null;
    pages.add(
      LocalSourcePage(
        file: file,
        relativePath: segments.join('/'),
        width: _positiveInt(raw['width']),
        height: _positiveInt(raw['height']),
      ),
    );
  }
  // pages.json 里出现了封面文件时，按显式页表处理（不偷偷丢掉用户声明的页）。
  return pages;
}

int? _positiveInt(Object? value) {
  final int? parsed = (value as num?)?.toInt();
  return parsed != null && parsed > 0 ? parsed : null;
}

String? _findCover(String mangaDirPath) {
  for (final FileSystemEntity entity in _list(Directory(mangaDirPath))) {
    if (entity is! File) continue;
    final String name = p.basename(entity.path).toLowerCase();
    if (kLocalSourceCoverFileNames.contains(name)) {
      return p.basename(entity.path);
    }
  }
  return null;
}

List<FileSystemEntity> _list(Directory dir) {
  try {
    return dir.listSync(followLinks: false);
  } on FileSystemException {
    return const <FileSystemEntity>[];
  }
}

bool _isPageImage(String path) =>
    kMangaImageExtensions.contains(p.extension(path).toLowerCase());

bool _isCoverFile(String path) =>
    kLocalSourceCoverFileNames.contains(p.basename(path).toLowerCase());

bool _isCoverRelativePath(String relativePath) =>
    !relativePath.contains('/') && _isCoverFile(relativePath);

bool _hasDotSegment(String relativePath) =>
    relativePath.split('/').any((String s) => s.startsWith('.'));

/// [path] 相对 [from] 的正斜杠路径（`.` = 同一路径）。
///
/// Local source 的 `relativePath` 一律用 `/`，跨平台持久化与 `p.posix` 拼接
/// 不因 Windows 的反斜杠而分叉。扫描、拖入登记与重建恢复共用这一处。
String localSourceRelativePath(String path, {required String from}) =>
    p.relative(path, from: from).replaceAll('\\', '/');
