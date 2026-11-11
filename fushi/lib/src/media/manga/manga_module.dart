import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/media/manga/manga_archive_importer.dart';
import 'package:fushi/src/media/manga/import/manga_folder_batch.dart';
import 'package:fushi_engine/media/manga/manga_importer.dart';




import 'package:fushi/utils.dart';

/// Narrow application-facing facade for the manga feature.
///
/// Generic book/navigation UI must call this facade instead of importing
/// reader, OCR, online-catalog, and storage implementations independently.
abstract final class MangaModule {
  static bool canImportPath(String path) =>
      mangaImportCanImport(<String>[path]);

  static Future<String> importMokuro({
    required FushiDatabase db,
    required String path,
    String? title,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
    void Function(int done, int total)? onProgress,
  }) =>
      MangaImporter.importFromMokuroPath(
        db: db,
        mokuroPath: path,
        title: title,
        policy: policy,
        onProgress: onProgress,
      );

  static bool isImageArchive(String path) =>
      MangaArchiveImporter.looksLikeImageArchive(path);

  /// 目录里有没有页图（[ImportCarrier] 的目录分支判据）。
  static bool directoryHasPageImages(String path) =>
      mangaDirectoryHasPageImages(path);

  /// 目录直接子层的整卷载体文件数（[ImportCarrier] 的目录分支判据）。
  static int directoryCarrierFileCount(String path) =>
      mangaCarrierFilesIn(Directory(path)).length;

  /// 目录直接子层的 `.mokuro` 数（[ImportCarrier] 的目录分支判据，BUG-2785）。
  static int directoryMokuroFileCount(String path) =>
      mangaMokuroFilesIn(Directory(path)).length;

  /// 目录直接子层**恰好一个** `.mokuro` 时返回它的路径，否则 null。
  ///
  /// 载体判成 [ImportCarrier.mangaMokuro] 的目录要经它换成那个文件再导入——
  /// `importMokuro` 吃的是 `.mokuro` 文件，不是目录。
  static String? directorySingleMokuroPath(String path) {
    final List<File> files = mangaMokuroFilesIn(Directory(path));
    return files.length == 1 ? files.single.path : null;
  }

  /// 一个装着整卷载体文件的目录 → 逐卷导入（BUG-1649）。一卷失败不中断整批，
  /// 每卷结局在返回的报告里，由调用方一次性汇报。
  static Future<MangaBatchImportReport> importBatchFolder({
    required FushiDatabase db,
    required String path,
    void Function(int done, int total)? onVolumeProgress,
  }) =>
      importMangaBatchFolder(
        db: db,
        path: path,
        onVolumeProgress: onVolumeProgress,
      );

  /// 一组同时选中 / 拖入的漫画载体逐卷导入（见 [importMangaBatchPaths]）。
  static Future<MangaBatchImportReport> importBatchPaths({
    required FushiDatabase db,
    required List<String> paths,
    void Function(int done, int total)? onVolumeProgress,
  }) =>
      importMangaBatchPaths(
        db: db,
        paths: paths,
        onVolumeProgress: onVolumeProgress,
      );

  /// 整目录页图导入（拖入一个漫画文件夹的落地路径）。OCR blocks 留空，之后可由
  /// 任一整卷引擎补齐——故 OCR 失败绝不会导致这本书消失。
  static Future<String> importImageFolder({
    required FushiDatabase db,
    required String path,
    String? title,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
    void Function(int done, int total)? onProgress,
  }) =>
      MangaImporter.importFromImageFolder(
        db: db,
        imageDirPath: path,
        title: title,
        policy: policy,
        onProgress: onProgress,
      );

  static Future<String> importArchive({
    required FushiDatabase db,
    required String path,
    String? title,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
    void Function(int done, int total)? onProgress,
    int? sourceId,
  }) =>
      MangaArchiveImporter.importArchive(
        db: db,
        archivePath: path,
        title: title,
        policy: policy,
        onProgress: onProgress,
        sourceId: sourceId,
      );
}
