import 'commands/library_commands.dart';
import 'commands/shelf_commands.dart';
import 'ctl_commands.dart';

/// 全部按域注册的命令组。my-comic 只保留漫画库与书架管理命令；
/// 词典 / 在线源 / 视频 / 设置 / AI 等非漫画命令组随 ticket 04 删除。
const List<CtlCommandGroup> kCtlCommandGroups = <CtlCommandGroup>[
  ...libraryCommandGroups,
  ...shelfCommandGroups,
];
