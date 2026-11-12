/// 顶层 tab 的逻辑身份（取代写死的整数索引 0/1/2）。条件 tab（video/browse 常驻、
/// games 仅 Windows）用枚举身份而非位置来切换/路由——插入条件 tab 不会再打乱「设置/词典」
/// 的索引（消除 `==2` / `case 1/2` / `%3` 这类特殊情况）。底栏/侧栏只在渲染层把身份映射
/// 成位置。games（galgame 库）紧跟在 video 之后。顶层 texthooker tab 已删（galgame 捕获
/// 工作台现内嵌于 games tab，会话见 `GalHookSessionController`）。
///
/// 独立成文件（`home_page.dart` 仍 re-export）是为了让平台层（长按图标快捷方式
/// 等）只依赖这个身份枚举，而不反向 import 整个首页实现。
/// Ticket 04 兼容保留：全部旧枚举值仍在（旧快捷方式 / 旧偏好 / 深链解析可能携带），
/// 但 my-comic 只渲染 Manga / 浏览 / 历史 / 下载 / 设置；其余值仅作历史身份存在。
enum HomeTab {
  home,
  books,
  manga,
  video,

  /// 浏览（Mihon 的 Browse：来源 / 扩展 / 发现 / 导入），2026-09-27 由「下载」改名。
  browse,

  /// 历史：一级导航页，只显示漫画阅读会话记录（`media_open_history`）。
  ///
  /// 不绑定 [ModuleId]（同设置 / 下载），由 `homeActiveTabs` 固定插在「浏览」与
  /// 「下载」之间，并跟随浏览 / 下载能力的平台门禁一起出现或消失。
  history,

  /// 下载：一级导航页，只显示漫画章节下载任务列表。2026-11-07 从浏览页的
  /// 「下载」视图页签迁出。不绑定 [ModuleId]（同设置），由 `homeActiveTabs`
  /// 跟在「浏览」之后，并跟随浏览 / 下载能力的平台门禁一起出现或消失。
  downloads,
  dictionaries,

  /// 复习（MyComic 内置 SRS）。模块默认关闭，见 `ModuleId.srs`。
  srs,
  games,
  browserExtension,
  settings,
}
