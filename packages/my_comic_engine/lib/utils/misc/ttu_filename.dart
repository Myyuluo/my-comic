/// ッツ Ebook Reader 兼容的书名 sanitize（跨设备书籍身份键）。
///
/// 原住在 `sync/ttu_filename.dart`（同步域）。我的漫画独立化后同步域已删除，
/// 但漫画导入（`MangaImporter` / `MangaArchiveImporter`）、书库查重
/// （`resolveDuplicateTitle`）与备份资产键仍以 `sanitizeTtuFilename(title)` 作为
/// 跨设备书籍身份，必须原样保留。这里只抽出纯字符串函数，不含同步用的
/// progress/statistics 文件名与解析。
///
/// 纯字符串变换，无 IO / 无平台依赖。格式与 ッツ web 实现一致（冻结，不随意改——
/// 改了会让既有书的跨设备身份键漂移）。
library;

String sanitizeTtuFilename(String title) {
  String result = title;
  if (result.endsWith(' ')) {
    result = '${result.substring(0, result.length - 1)}~ttu-spc~';
  }
  if (result.endsWith('.')) {
    result = '${result.substring(0, result.length - 1)}~ttu-dend~';
  }
  result = result.replaceAll('*', '~ttu-star~');
  result = result.replaceAllMapped(
    RegExp(r'[/?\<>\\:|%"]'),
    (match) => match[0]!.codeUnits
        .map((c) => '%${c.toRadixString(16).toUpperCase().padLeft(2, '0')}')
        .join(),
  );
  return result;
}
