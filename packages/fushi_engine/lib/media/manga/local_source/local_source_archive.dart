/// Local source（ADR 0013）里的 CBZ 章节只读访问。
///
/// CBZ = 标准 ZIP：页图 + 可选的包根 `pages.json`。本文件只读条目表、按需读取
/// 条目内容，**不解压到磁盘、不复制**；阅读器把要显示的页按需落到 `cache`，
/// `localcomic` 里的原包始终不动。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show naturalCompare;
import 'package:fushi_engine/media/manga/manga_importer.dart'
    show kMangaImageExtensions;

/// 包根页表文件名（与文件夹章节的 `pages.json` 同名）。
const String kLocalSourceArchivePagesJsonEntry = 'pages.json';

/// ZIP 条目名归一化：统一正斜杠、去掉空段与 `.` 段。
///
/// `..` 段不在这里删除——调用方要能看见它并拒绝（防穿越）。
String normalizeLocalSourceArchiveEntryName(String raw) => raw
    .replaceAll('\\', '/')
    .split('/')
    .where((String segment) => segment.isNotEmpty && segment != '.')
    .join('/');

/// 一个常规文件条目。
class LocalSourceArchiveEntry {
  const LocalSourceArchiveEntry({required this.name, required this.size});

  /// 归一化后的条目名（正斜杠）。
  final String name;

  /// 解压后字节数。
  final int size;

  bool get isImage =>
      kMangaImageExtensions.contains(p.posix.extension(name).toLowerCase());
}

/// `pages.json` 条目或图片扫描得到的一页。
class LocalSourceArchivePage {
  const LocalSourceArchivePage({
    required this.relativePath,
    this.width,
    this.height,
  });

  /// 包内条目名（归一化、正斜杠；`pages.json` 声明的顺序）。
  final String relativePath;

  /// `pages.json` 声明的宽高；图片扫描回退时未知。
  final int? width;
  final int? height;
}

/// 打开的 CBZ：条目表 + 按需读取条目字节。
///
/// [InputFileStream] 必须活到最后一次 [readEntry]；[close] 释放句柄与已解压
/// 缓冲。构造用 [open]。
class LocalSourceArchive {
  LocalSourceArchive._({
    required this.path,
    required InputFileStream input,
    required Archive archive,
    required List<LocalSourceArchiveEntry> entries,
    required Map<String, ArchiveFile> exact,
    required Map<String, ArchiveFile> folded,
  }) : _input = input,
       _archive = archive,
       _entries = entries,
       _exact = exact,
       _folded = folded;

  /// 打开 [archivePath]（只读中央目录；条目内容惰性解压）。
  ///
  /// 文件不存在 / 不是合法 ZIP 时抛 [FileSystemException] / [FormatException]。
  static LocalSourceArchive open(String archivePath) {
    final File file = File(archivePath);
    if (!file.existsSync()) {
      throw FileSystemException('Local source archive not found', archivePath);
    }
    final InputFileStream input = InputFileStream(archivePath);
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBuffer(input);
    } on Object {
      input.closeSync();
      rethrow;
    }
    final List<LocalSourceArchiveEntry> entries = <LocalSourceArchiveEntry>[];
    final Map<String, ArchiveFile> exact = <String, ArchiveFile>{};
    final Map<String, List<ArchiveFile>> foldedLists =
        <String, List<ArchiveFile>>{};
    for (final ArchiveFile entry in archive.files) {
      if (!entry.isFile || entry.isSymbolicLink) continue;
      final String name = normalizeLocalSourceArchiveEntryName(entry.name);
      if (name.isEmpty) continue;
      entries.add(LocalSourceArchiveEntry(name: name, size: entry.size));
      exact.putIfAbsent(name, () => entry);
      final String folded = name.toLowerCase();
      (foldedLists[folded] ??= <ArchiveFile>[]).add(entry);
    }
    // 大小写折叠只接受唯一匹配：两个只差大小写的条目是歧义，不猜。
    final Map<String, ArchiveFile> folded = <String, ArchiveFile>{
      for (final MapEntry<String, List<ArchiveFile>> item
          in foldedLists.entries)
        if (item.value.length == 1) item.key: item.value.single,
    };
    return LocalSourceArchive._(
      path: archivePath,
      input: input,
      archive: archive,
      entries: List<LocalSourceArchiveEntry>.unmodifiable(entries),
      exact: exact,
      folded: folded,
    );
  }

  /// 包路径（原始大小写）。
  final String path;

  final InputFileStream _input;
  final Archive _archive;
  final List<LocalSourceArchiveEntry> _entries;
  final Map<String, ArchiveFile> _exact;
  final Map<String, ArchiveFile> _folded;
  bool _closed = false;

  /// 常规文件条目（归一化名，按中央目录顺序）。
  List<LocalSourceArchiveEntry> get entries => _entries;

  /// 按归一化条目名读取解压后字节；条目不存在 / 读取失败返回 null。
  ///
  /// 记录了 CRC 的条目会核对 CRC——截断/位翻转的坏页宁可读不到，也不把垃圾
  /// 字节交给阅读器。
  Uint8List? readEntry(String entryName) {
    if (_closed) {
      throw StateError('Local source archive is closed: $path');
    }
    final String name = normalizeLocalSourceArchiveEntryName(entryName);
    final ArchiveFile? entry = _exact[name] ?? _folded[name.toLowerCase()];
    if (entry == null) return null;
    final Object? content = entry.content;
    if (content is! List<int>) return null;
    final Uint8List bytes = content is Uint8List
        ? content
        : Uint8List.fromList(content);
    final int? expectedCrc = entry.crc32;
    if (expectedCrc != null && getCrc32(bytes) != expectedCrc) return null;
    return bytes;
  }

  /// 关闭文件句柄并释放缓冲。
  void close() {
    if (_closed) return;
    _closed = true;
    _archive.clearSync();
    _input.closeSync();
  }
}

/// CBZ 章节的页表：包根 `pages.json` 优先；缺失、损坏、引用缺页时回退到
/// 包内图片自然序扫描。
List<LocalSourceArchivePage> readLocalSourceArchivePages(
  LocalSourceArchive archive,
) {
  final List<LocalSourceArchivePage>? fromJson = _pagesFromRootJson(archive);
  if (fromJson != null) return fromJson;
  return _scanImageEntries(archive);
}

/// 包内图片扫描：跳过点段（`.DS_Store` 等）与 macOS `__MACOSX` 产物，按
/// 相对路径自然序。
List<LocalSourceArchivePage> _scanImageEntries(LocalSourceArchive archive) {
  final List<LocalSourceArchivePage> pages = <LocalSourceArchivePage>[];
  for (final LocalSourceArchiveEntry entry in archive.entries) {
    if (!entry.isImage) continue;
    if (_hasJunkSegment(entry.name)) continue;
    pages.add(LocalSourceArchivePage(relativePath: entry.name));
  }
  pages.sort(
    (LocalSourceArchivePage a, LocalSourceArchivePage b) =>
        naturalCompare(a.relativePath, b.relativePath),
  );
  return pages;
}

bool _hasJunkSegment(String name) => name
    .split('/')
    .any(
      (String segment) =>
          segment.startsWith('.') || segment.toLowerCase() == '__macosx',
    );

List<LocalSourceArchivePage>? _pagesFromRootJson(LocalSourceArchive archive) {
  final Uint8List? bytes = archive.readEntry(kLocalSourceArchivePagesJsonEntry);
  if (bytes == null) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on Object {
    return null;
  }
  if (decoded is! Map<Object?, Object?>) return null;
  final Object? rawPages = decoded['pages'];
  if (rawPages is! List<Object?> || rawPages.isEmpty) return null;

  final List<LocalSourceArchivePage> pages = <LocalSourceArchivePage>[];
  for (final Object? raw in rawPages) {
    if (raw is! Map<Object?, Object?>) return null;
    final String url = raw['url']?.toString().trim() ?? '';
    if (url.isEmpty) return null;
    final List<String> segments = url
        .replaceAll('\\', '/')
        .split('/')
        .where((String segment) => segment.isNotEmpty && segment != '.')
        .toList();
    if (segments.isEmpty || segments.any((String segment) => segment == '..')) {
      return null;
    }
    final String normalized = segments.join('/');
    if (!_hasEntry(archive, normalized)) return null;
    pages.add(
      LocalSourceArchivePage(
        relativePath: normalized,
        width: _positiveInt(raw['width']),
        height: _positiveInt(raw['height']),
      ),
    );
  }
  return pages;
}

bool _hasEntry(LocalSourceArchive archive, String name) {
  return archive.entries.any((LocalSourceArchiveEntry entry) {
    return entry.name == name || entry.name.toLowerCase() == name.toLowerCase();
  });
}

int? _positiveInt(Object? value) {
  final int? parsed = (value as num?)?.toInt();
  return parsed != null && parsed > 0 ? parsed : null;
}
