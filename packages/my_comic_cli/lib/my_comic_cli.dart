/// MyComic 桌面客户端命令行与本机控制通道。
///
/// - app 侧：[CtlServer] + [CtlDesktopHandler]（`my_comic/lib/src/platform/desktop/desktop_ctl_host.dart` 接线）。
/// - CLI 侧：[runMyComicCli]（`bin/my_comic_cli.dart`）。
/// - 两侧共用：[CtlEndpoint] 发现文件与 [resolveCtlStateDir] 路径约定。
library;

export 'src/ctl_cli.dart';
export 'src/ctl_client.dart';
export 'src/ctl_endpoint.dart';
export 'src/ctl_launcher.dart';
export 'src/ctl_paths.dart';
export 'src/ctl_protocol.dart';
export 'src/ctl_routes.dart';
export 'src/ctl_command_registry.dart';
export 'src/ctl_commands.dart';
export 'src/ctl_server.dart';
