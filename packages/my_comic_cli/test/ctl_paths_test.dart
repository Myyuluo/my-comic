import 'package:my_comic_cli/my_comic_cli.dart';
import 'package:test/test.dart';

void main() {
  group('resolveCtlStateDir', () {
    test('MYCOMIC_CTL_DIR 优先于一切', () {
      expect(
        resolveCtlStateDir(
          environment: <String, String>{
            kCtlDirEnv: '/x/ctl',
            'HOME': '/home/u',
          },
          operatingSystem: 'linux',
          testRoot: '/t',
        ),
        '/x/ctl',
      );
    });

    test('测试根隔离用户真实发现文件', () {
      expect(
        resolveCtlStateDir(
          environment: <String, String>{'HOME': '/home/u'},
          operatingSystem: 'linux',
          testRoot: '/t',
        ),
        '/t/ctl',
      );
    });

    test('测试根按目标平台拼路径（与宿主平台无关）', () {
      expect(
        resolveCtlStateDir(
          environment: const <String, String>{},
          operatingSystem: 'windows',
          testRoot: r'C:\t',
        ),
        r'C:\t\ctl',
      );
    });

    test('Windows 落 LOCALAPPDATA', () {
      expect(
        resolveCtlStateDir(
          environment: <String, String>{
            'LOCALAPPDATA': r'C:\Users\u\AppData\Local',
          },
          operatingSystem: 'windows',
        ),
        r'C:\Users\u\AppData\Local\MyComic\ctl',
      );
    });

    test('macOS 落 Application Support', () {
      expect(
        resolveCtlStateDir(
          environment: <String, String>{'HOME': '/Users/u'},
          operatingSystem: 'macos',
        ),
        '/Users/u/Library/Application Support/MyComic/ctl',
      );
    });

    test('Linux 优先 XDG_STATE_HOME，缺省 ~/.local/state', () {
      expect(
        resolveCtlStateDir(
          environment: <String, String>{
            'XDG_STATE_HOME': '/s',
            'HOME': '/home/u',
          },
          operatingSystem: 'linux',
        ),
        '/s/my_comic/ctl',
      );
      expect(
        resolveCtlStateDir(
          environment: <String, String>{'HOME': '/home/u'},
          operatingSystem: 'linux',
        ),
        '/home/u/.local/state/my_comic/ctl',
      );
    });

    test('缺系统目录时返回 null', () {
      expect(
        resolveCtlStateDir(
          environment: const <String, String>{},
          operatingSystem: 'windows',
        ),
        isNull,
      );
    });
  });

  group('myComicAppCandidates', () {
    test('显式路径 > MYCOMIC_APP > CLI 同级 > 默认安装位置', () {
      expect(
        myComicAppCandidates(
          environment: <String, String>{
            kMyComicAppEnv: r'D:\env\MyComic.exe',
            'LOCALAPPDATA': r'C:\L',
          },
          operatingSystem: 'windows',
          cliExecutable: r'C:\L\MyComic\my_comic_cli.exe',
          explicitPath: r'D:\explicit\MyComic.exe',
        ),
        <String>[
          r'D:\explicit\MyComic.exe',
          r'D:\env\MyComic.exe',
          r'C:\L\MyComic\MyComic.exe',
          r'C:\L\MyComic\MyComic.exe',
        ],
      );
    });

    test('macOS 带 /Applications 下的 app 包', () {
      final List<String> candidates = myComicAppCandidates(
        environment: <String, String>{'HOME': '/Users/u'},
        operatingSystem: 'macos',
        cliExecutable: '/usr/local/bin/my_comic_cli',
      );
      expect(candidates, contains('/Applications/mycomic.app'));
      expect(candidates, contains('/Users/u/Applications/MyComic.app'));
    });
  });
}
