import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi_engine/media/manga/import/image_size_probe.dart'
    show probeOrientedImageSize;
import 'package:fushi_engine/media/manga/local_source/local_source_archive.dart';

abstract interface class MangaPageProvider {
  Future<MangaReaderSession> open();
}

/// 阅读器的页会话契约。
///
/// 两个实现：[LocalMangaReaderSession]（本地导入卷 / 已下载的在线章，一份本地
/// `manga.json + images/`）与 `OnlineMangaReaderSession`（未下载的在线章直读，
/// 2026-09-26 用户撤回设计稿 §1.1「必须先下载再读」后恢复；页经适配器懒取、
/// 落在 app 临时目录的会话私有缓存里，不碰章下载目录）。
abstract interface class MangaReaderSession {
  int get pageCount;

  Future<MangaPageBytes> page(int index);

  /// Return a local file containing this page.
  Future<File?> localFile(int index);

  /// Stable identity used by the OCR cache.
  String cacheIdentity(int index);

  Future<void> close();
}

class MangaPageBytes {
  const MangaPageBytes({
    required this.bytes,
    required this.contentType,
    this.width,
    this.height,
  });

  final Uint8List bytes;
  final String contentType;
  final int? width;
  final int? height;

  bool get hasDimensions =>
      width != null && height != null && width! > 0 && height! > 0;
}

/// Adapter used by the existing managed local-manga reader.
class LocalMangaPageProvider implements MangaPageProvider {
  const LocalMangaPageProvider({
    required this.imagesRoot,
    required this.relativePaths,
  });

  final Directory imagesRoot;
  final List<String> relativePaths;

  @override
  Future<MangaReaderSession> open() async => LocalMangaReaderSession(
    imagesRoot: imagesRoot,
    relativePaths: List<String>.unmodifiable(relativePaths),
  );
}

class LocalMangaReaderSession implements MangaReaderSession {
  LocalMangaReaderSession({
    required this.imagesRoot,
    required this.relativePaths,
  });

  final Directory imagesRoot;
  final List<String> relativePaths;
  bool _closed = false;

  @override
  int get pageCount => relativePaths.length;

  @override
  Future<MangaPageBytes> page(int index) async {
    final File file = await _validatedFile(index);
    final Uint8List bytes = await file.readAsBytes();
    final ({int width, int height})? dimensions = await mangaImageDimensions(
      bytes,
    );
    return MangaPageBytes(
      bytes: bytes,
      contentType: mangaImageContentType(bytes),
      width: dimensions?.width,
      height: dimensions?.height,
    );
  }

  @override
  Future<File?> localFile(int index) async => _validatedFile(index);

  Future<File> _validatedFile(int index) async {
    if (_closed) {
      throw const MihonRuntimeException(
        'SESSION_CLOSED',
        'The local manga reader session is closed',
      );
    }
    if (index < 0 || index >= relativePaths.length) {
      throw RangeError.index(index, relativePaths, 'index');
    }
    final String root = p.canonicalize(imagesRoot.path);
    final String candidate = p.canonicalize(
      p.join(imagesRoot.path, relativePaths[index]),
    );
    if (!p.isWithin(root, candidate)) {
      throw const MihonRuntimeException(
        'PATH_TRAVERSAL',
        'Local manga page escaped the managed image directory',
      );
    }
    final File file = File(
      p.normalize(p.absolute(p.join(imagesRoot.path, relativePaths[index]))),
    );
    if (!await file.exists()) {
      throw const MihonRuntimeException(
        'PAGE_MISSING',
        'Local manga page is missing',
      );
    }
    return file;
  }

  @override
  String cacheIdentity(int index) {
    if (index < 0 || index >= relativePaths.length) {
      throw RangeError.index(index, relativePaths, 'index');
    }
    return relativePaths[index];
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

/// Local source CBZ 章节的页缓存根名（app cache root 下）。
const String kLocalSourceArchiveCacheDirName = 'local_source_archive_cache';

/// Local source CBZ 章节的页会话：按需把正在读的页从压缩包解到 app cache，
/// [close] 时删掉整个会话目录。`localcomic` 里的原包始终只读、不复制。
class LocalSourceArchivePageProvider implements MangaPageProvider {
  const LocalSourceArchivePageProvider({
    required this.archivePath,
    required this.cacheRoot,
    required this.relativePaths,
  });

  /// CBZ 绝对路径。
  final String archivePath;

  /// 会话页缓存根（`<cache>/local_source_archive_cache`）。
  final Directory cacheRoot;

  /// 页在包内的条目名（顺序即页序）。
  final List<String> relativePaths;

  @override
  Future<MangaReaderSession> open() => LocalSourceArchiveReaderSession.open(
    archivePath: archivePath,
    cacheRoot: cacheRoot,
    relativePaths: relativePaths,
  );
}

class LocalSourceArchiveReaderSession implements MangaReaderSession {
  LocalSourceArchiveReaderSession._({
    required this.directory,
    required LocalSourceArchive archive,
    required List<String> relativePaths,
  }) : _archive = archive,
       _relativePaths = List<String>.unmodifiable(relativePaths);

  /// 开一个会话：页缓存目录 = `<cacheRoot>/session-<seq>`。
  ///
  /// 打开前清掉 [cacheRoot] 下不属于活会话的残目录（上次崩溃 / 被杀的残留）。
  static Future<LocalSourceArchiveReaderSession> open({
    required String archivePath,
    required Directory cacheRoot,
    required List<String> relativePaths,
  }) async {
    final Directory directory = Directory(
      p.join(cacheRoot.path, 'session-${_sessionSequence++}'),
    );
    _activeDirectories.add(p.canonicalize(directory.path));
    try {
      await pruneStaleLocalSourceArchiveCaches(cacheRoot);
      await directory.create(recursive: true);
      return LocalSourceArchiveReaderSession._(
        directory: directory,
        archive: LocalSourceArchive.open(archivePath),
        relativePaths: relativePaths,
      );
    } on Object {
      _activeDirectories.remove(p.canonicalize(directory.path));
      try {
        if (await directory.exists()) await directory.delete(recursive: true);
      } on Object {
        // 缓存清理 best effort。
      }
      rethrow;
    }
  }

  /// 删掉 [cacheRoot] 下所有不属于活会话的条目（残目录 / 散落文件）。
  static Future<void> pruneStaleLocalSourceArchiveCaches(
    Directory cacheRoot,
  ) async {
    if (!await cacheRoot.exists()) return;
    await for (final FileSystemEntity entity in cacheRoot.list()) {
      if (entity is Directory &&
          _activeDirectories.contains(p.canonicalize(entity.path))) {
        continue;
      }
      try {
        await entity.delete(recursive: true);
      } on Object {
        // 缓存清理 best effort：个别文件被占用不影响阅读。
      }
    }
  }

  static final Set<String> _activeDirectories = <String>{};
  static int _sessionSequence = 0;

  /// 本会话的页缓存目录。
  final Directory directory;

  final LocalSourceArchive _archive;
  final List<String> _relativePaths;
  final Map<int, File> _extracted = <int, File>{};
  final Map<int, Future<File>> _pending = <int, Future<File>>{};
  bool _closed = false;

  bool get isClosed => _closed;

  @override
  int get pageCount => _relativePaths.length;

  @override
  Future<MangaPageBytes> page(int index) async {
    final File file = await _file(index);
    final Uint8List bytes = await file.readAsBytes();
    final ({int width, int height})? dimensions = await mangaImageDimensions(
      bytes,
    );
    return MangaPageBytes(
      bytes: bytes,
      contentType: mangaImageContentType(bytes),
      width: dimensions?.width,
      height: dimensions?.height,
    );
  }

  @override
  Future<File?> localFile(int index) => _file(index);

  /// 稳定身份供 OCR / 卡图缓存：包路径 + 条目名，跨会话一致。
  @override
  String cacheIdentity(int index) {
    _validate(index);
    return 'local-cbz\u001f'
        '${p.canonicalize(_archive.path).toLowerCase()}\u001f'
        '${_relativePaths[index]}';
  }

  Future<File> _file(int index) {
    _validate(index);
    final File? cached = _extracted[index];
    if (cached != null) return Future<File>.value(cached);
    final Future<File>? pending = _pending[index];
    if (pending != null) return pending;
    late final Future<File> tracked;
    tracked = _extract(index)
        .then((File file) {
          _extracted[index] = file;
          return file;
        })
        .whenComplete(() {
          if (identical(_pending[index], tracked)) _pending.remove(index);
        });
    _pending[index] = tracked;
    return tracked;
  }

  Future<File> _extract(int index) async {
    final Uint8List? bytes = _archive.readEntry(_relativePaths[index]);
    if (bytes == null) {
      throw MihonRuntimeException(
        'PAGE_MISSING',
        'Local source archive page is missing: ${_relativePaths[index]}',
      );
    }
    String extension = p.extension(_relativePaths[index]).toLowerCase();
    if (extension.isEmpty) extension = '.jpg';
    final File file = File(
      p.join(
        directory.path,
        'page_${index.toString().padLeft(6, '0')}$extension',
      ),
    );
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  void _validate(int index) {
    if (_closed) {
      throw const MihonRuntimeException(
        'SESSION_CLOSED',
        'The local source archive reader session is closed',
      );
    }
    if (index < 0 || index >= _relativePaths.length) {
      throw RangeError.index(index, _relativePaths, 'index');
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _archive.close();
    _activeDirectories.remove(p.canonicalize(directory.path));
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on Object {
      // Windows 上被杀软 / WebView 占用时删不掉：缓存目录可丢弃，下次 open
      // 会 prune 掉。
    }
  }
}

/// 页图（按 EXIF 方向摆正后的）宽高。
///
/// BUG-3041：阅读器每个页图请求（WebView 拦截 `/img/`、面板检测、在线直读首页）
/// 都经 [MangaReaderSession.page] 走到这里。以前一律 `img.decodeImage` 整张纯
/// Dart 解码——2400×3400 的页在桌面要 0.5~0.7 s、几十 MB 堆，iOS 自定义 scheme
/// 又没有 HTTP 缓存，大图卷每次装窗口 / 翻页都要重付，阅读与查词一起被拖慢。
/// 宽高只需文件头：先走与导入同一口径的 [probeOrientedImageSize]（JPEG 读到
/// SOF + EXIF 方向、PNG 读 IHDR、WebP 读 VP8 头，零像素解码），认不出的格式
/// （GIF / 损坏头）才回退后台 isolate 整张解码，结果与从前一致。
Future<({int width, int height})?> mangaImageDimensions(Uint8List bytes) async {
  if (bytes.isEmpty) return null;
  final ({int width, int height})? probed = probeOrientedImageSize(bytes);
  if (probed != null) return probed;
  return Isolate.run<({int width, int height})?>(() {
    try {
      final img.Image? decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      final img.Image oriented = img.bakeOrientation(decoded);
      return (width: oriented.width, height: oriented.height);
    } on Object {
      return null;
    }
  });
}

String mangaImageContentType(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return 'image/jpeg';
  }
  if (bytes.length >= 6 &&
      (String.fromCharCodes(bytes.take(6)) == 'GIF89a' ||
          String.fromCharCodes(bytes.take(6)) == 'GIF87a')) {
    return 'image/gif';
  }
  if (bytes.length >= 12 &&
      String.fromCharCodes(bytes.take(4)) == 'RIFF' &&
      String.fromCharCodes(bytes.skip(8).take(4)) == 'WEBP') {
    return 'image/webp';
  }
  return 'application/octet-stream';
}
