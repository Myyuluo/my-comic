/// Local source root（ADR 0013）的目录扫描与章节识别。
///
/// `localcomic/{manga}/{chapter}/` 是 Mihon local-source layout：
/// - 第一层目录 = 一部 Manga；
/// - Manga 目录下的每个含页图的直接子目录 = 一个 Chapter；
/// - Manga 目录**直接**含页图时，整本目录算单章（不再拆子目录）；
/// - `cover.jpg`（也接受 jpeg/png）只作封面，不算页；
/// - 章节目录里可选的 `pages.json` 决定页序；缺失、损坏或缺页时回退到按
///   自然序扫描图片。
///
/// 扫描只读文件系统，不写任何文件——Local source 原地读取、不复制（ADR 0013）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show naturalCompare;
import 'package:fushi_engine/media/manga/manga_importer.dart'
    show kMangaImageExtensions;
import 'package:fushi_engine/media/manga/page_enumeration.dart';

/// 章节目录内可选的页表文件名（与 Download library 的 `pages.json` 同名）。
const String kLocalSourcePagesJsonFileName = 'pages.json';

/// 被识作封面的文件名（小写）。与既有封面解析器
/// `ReaderFushiSource.resolveCoverFilePath` 的候选一致。
const Set<String> kLocalSourceCoverFileNames = <String>{
  'cover.jpg',
  'cover.jpeg',
  'cover.png',
};

/// 单章（manga 目录直接含页图）的章节 key。真实子目录名不可能等于 `.`。
const String kLocalSourceRootChapterKey = '.';

/// 一张页图：磁盘文件 + 相对章节目录的正斜杠路径。
class LocalSourcePage {
  const LocalSourcePage({
    required this.file,
    required this.relativePath,
    this.width,
    this.height,
  });

  final File file;

  /// 相对章节目录的正斜杠路径（`001.jpg` / `vol1/001.jpg`）。
  final String relativePath;

  /// `pages.json` 声明的宽高；扫描回退时未知（阅读器按文件头探测）。
  final int? width;
  final int? height;
}

/// 一个章节目录。
class LocalSourceChapter {
  const LocalSourceChapter({
    required this.key,
    required this.name,
    required this.relativePath,
    required this.pages,
  });

  /// 章节身份 = 相对 Manga 目录的路径（单章为 [kLocalSourceRootChapterKey]）。
  /// 目录改名/移动 = 新 key（ADR 0013：作品身份按文件夹路径认）。
  final String key;

  /// 展示名（章节目录名；单章为 Manga 目录名）。
  final String name;

  /// 相对 Manga 目录的正斜杠路径；单章为空串。
  final String relativePath;

  final List<LocalSourcePage> pages;

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

Future<LocalSourceManga?> _scanManga(Directory root, Directory mangaDir) async {
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
    final List<Directory> chapterDirs =
        <Directory>[
          for (final FileSystemEntity entity in entries)
            if (entity is Directory &&
                !p.basename(entity.path).startsWith('.') &&
                p.basename(entity.path) != 'manga_ocr_out')
              entity,
        ]..sort(
          (Directory a, Directory b) =>
              naturalCompare(p.basename(a.path), p.basename(b.path)),
        );
    for (final Directory chapterDir in chapterDirs) {
      final List<LocalSourcePage> pages = await readLocalSourceChapterPages(
        chapterDir.path,
        isRootChapter: false,
      );
      if (pages.isEmpty) continue;
      final String relative = _relativeForward(
        chapterDir.path,
        from: mangaDir.path,
      );
      chapters.add(
        LocalSourceChapter(
          key: relative,
          name: p.basename(chapterDir.path),
          relativePath: relative,
          pages: pages,
        ),
      );
    }
  }
  if (chapters.isEmpty) return null;
  return LocalSourceManga(
    title: title,
    directoryPath: mangaDir.path,
    relativePath: _relativeForward(mangaDir.path, from: root.path),
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
    if (kLocalSourceCoverFileNames.contains(name))
      return p.basename(entity.path);
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

String _relativeForward(String path, {required String from}) =>
    p.relative(path, from: from).replaceAll('\\', '/');
