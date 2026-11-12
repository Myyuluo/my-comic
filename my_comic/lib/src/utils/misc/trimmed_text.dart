/// 归一化「可选文本」：null / 空串 / 纯空白 → null；其它值取 `toString().trim()`。
///
/// 备份描述符、导入报告与缺失来源文案都只关心「有没有可读文本」，共用这一条
/// 规则，避免每个调用点各写一遍 `trim().isEmpty` 判断。
String? trimmedOrNull(Object? value) {
  final String? text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}
