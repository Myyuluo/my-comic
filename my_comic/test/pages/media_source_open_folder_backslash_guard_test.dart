import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/utils/misc/reveal_in_file_manager.dart';

/// BUG-920 守卫：把正斜杠目录交给 Windows explorer.exe 前必须转回反斜杠。
///
/// 根因：normalizeSourceRootPath 把本地 rootPath 归一化为正斜杠（跨平台一致 +
/// dedup/label 依赖），而 explorer.exe 只认反斜杠路径参数——传正斜杠会被忽略、
/// 改开默认「文档」目录。存储层归一化不动，仅在 explorer 平台边界做方向转换。
/// 媒体来源管理页已随视频 / 游戏域删除，但方向转换仍收在保留的文件管理器原语里。
void main() {
  test('原语的 Windows 分支把正斜杠目录转成反斜杠', () {
    final RevealCommand command = revealCommand(
      host: RevealHost.windows,
      path: 'D:/Anime/Season 1',
      isDirectory: true,
    );
    expect(command.executable, 'explorer');
    expect(command.arguments, <String>[r'D:\Anime\Season 1']);
  });
}
