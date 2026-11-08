/// Source 语言里「不区分语言」的占位值（与 Mihon 的约定一致）。
///
/// Mihon 多语言单源扩展用空字符串 / `all` / `multi` 表示「本源的章节不按语言
/// 拆分」。下载目录命名（`源名 (LANG)`）与语言作用域（同语言镜像源 chip）都要
/// 把这三个值当作「没有可区分的语言」：前者不写 `(ALL)` 这种无意义后缀，后者
/// 不生成语言比较。集中在这里，避免服务与运行时适配器各持一份。
library;

/// 视为「不区分语言」的 Source 语言值（小写比较）。
const Set<String> kLanguageAgnosticSourceLanguages = <String>{'', 'all', 'multi'};

/// [language] 是否是「不区分语言」的占位值：空、`all`、`multi`（大小写不敏感，
/// 首尾空白忽略）。
bool isLanguageAgnosticSourceLanguage(String? language) =>
    kLanguageAgnosticSourceLanguages.contains(
      (language ?? '').trim().toLowerCase(),
    );
