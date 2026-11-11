import 'package:url_launcher/url_launcher.dart';

import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 项目主页（GitHub fork）。下载页与新手引导从这里取值，URL 只存在一处。
///
/// MyComic 是独立发行版，不再指向上游官网；更新资产也由本仓库的 Release 发布。
const String kOfficialWebsiteUrl = 'https://github.com/Myyuluo/my-comic';

/// 项目 Release 页。安装包、更新资产与发行说明都在这里。
const String kOfficialDownloadPageUrl = '$kOfficialWebsiteUrl/releases';

/// my-comic 的 GitHub 仓库。宽屏侧栏左上角的品牌图标与「设置 · 通用 · GitHub」
/// 都指向这里；这是本项目的仓库，不是上游 Fushi 仓库。URL 只存在一处。
const String kMyComicRepositoryUrl = 'https://github.com/Myyuluo/my-comic';

/// 在系统浏览器里打开官网下载页。打不开返回 false，**不抛**（理由同
/// [openMyComicRepository]）。
Future<bool> openOfficialDownloadPage() async {
  try {
    return await launchUrl(
      Uri.parse(kOfficialDownloadPageUrl),
      mode: LaunchMode.externalApplication,
    );
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('openOfficialDownloadPage', error, stack);
    return false;
  }
}

/// 在系统浏览器里打开 my-comic 的 GitHub 仓库。打不开返回 false，**不抛**。
///
/// 调用点可能挂在同步 `onTap` 上（接不住 future），所以异常必须在这里收口：
/// `launchUrl` 在没有 handler 的环境（Linux 缺 xdg-open、企业策略禁外链）会
/// throw，漏出去就是一次未捕获异步异常。
Future<bool> openMyComicRepository() async {
  try {
    return await launchUrl(
      Uri.parse(kMyComicRepositoryUrl),
      mode: LaunchMode.externalApplication,
    );
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('openMyComicRepository', error, stack);
    return false;
  }
}
