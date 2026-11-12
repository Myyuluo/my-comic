/// 漫画阅读器的内容语言身份。
///
/// 原住在 `my_comic_dictionary` 的 `Language` / `JapaneseLanguage` 体系：书架 provider
/// 以语言对象为 family key。我的漫画只支持日本漫画一条阅读链，独立化后词典包删除，
/// 这里保留最小身份对象（类名不变，避免扩散到调用方）：
///
/// - [Language] 只是 family key 的身份类型，按对象身份比较；
/// - [JapaneseLanguage.instance] 是唯一实例；
/// - [JapaneseLanguage.initialise] 是启动预热钩子，漫画链不需要词典资源，保持空实现。
///
/// 不承载词典分词 / 字体链 / 语言选择语义（那些已随词典域删除）。
library;

class Language {
  const Language();
}

class JapaneseLanguage extends Language {
  JapaneseLanguage._();

  static final JapaneseLanguage instance = JapaneseLanguage._();

  /// 启动预热钩子（原词典实现用于准备分词资源）。漫画链无资源可准备。
  Future<void> initialise() async {}
}
