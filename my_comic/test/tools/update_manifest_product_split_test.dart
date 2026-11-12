import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/utils/misc/platform_updater.dart';
import 'package:my_comic/src/utils/misc/update_checker.dart';
import 'package:path/path.dart' as p;

/// BUG-1481 守卫：**发布通道必须按产品族分开**。
///
/// 改名过渡期两个产品从同一个 GitHub 仓库发版——桥包 `app.hibiki.reader`（bridge 分支）
/// 和本体 `app.mycomic.reader`。一个仓库只有一条 `update-manifest` 分支、一套 release tag，
/// 于是「只按通道分」的文件名和「全族共用」的 rolling tag 让两族撞在一起：
///
/// 1. 两族写同一个 `latest-<channel>.json`，CI `merge_update_manifest.py` 的单调 seq
///    守卫把顶层 release 永久判给 commit 数更高的一族 → 另一族客户端读到的
///    version/tag/assets 全不是自己的，自更新**不可能成功**（这条最致命：老 Hibiki
///    用户升不到迁移桥包）。
/// 2. 两族资产挂同一个 `debug-rolling` tag，而 prune 只按平台分组取 top N seq
///    → 低 seq 的那一族每次被另一族的构建删干净。
///
/// 历史名（`latest-<channel>.json` / `debug-rolling`）**冻结给 hibiki 族**：已在野的
/// Hibiki 客户端把那些 URL 编译进了包里，改不动。所以让路的必须是本体。
///
/// 这些用例是「不许退回共用」的硬门：任何一侧改回历史名都会红。
void main() {
  late Directory repoRoot;

  setUpAll(() {
    // 测试的 cwd 是 `my_comic/`，仓库根是它的上一级。
    repoRoot = Directory.current.parent;
    expect(
      File(p.join(repoRoot.path, 'tool', 'publish_update_manifest.sh'))
          .existsSync(),
      isTrue,
      reason: 'repo root resolved wrong: ${repoRoot.path}',
    );
  });

  group('客户端读的清单 URL 带产品族', () {
    // 冻结给 hibiki 族的历史文件名。**故意写成字面量**而不是从
    // [kMyComicManifestSuffix] 推导：用常量拼断言的话，把常量改成空串会让断言退化成
    // `endsWith('.json')` 恒真，守卫自己先失效（这个洞是变异实测打出来的）。
    // 这三个名字由已在野、改不动的老客户端定义，本来就是外部常量。
    const List<String> frozenHibikiManifests = <String>[
      'latest-beta.json',
      'latest-debug.json',
      'latest-stable.json',
    ];

    test('三个通道的每个镜像 URL 都不是 hibiki 族的历史文件名', () {
      expect(UpdateChannel.values.length, frozenHibikiManifests.length,
          reason: '新增通道时必须同步补一条冻结名，否则新通道会漏出守卫');
      for (final UpdateChannel channel in UpdateChannel.values) {
        final String? url = manifestUrlForChannel(channel);
        expect(url, isNotNull, reason: '$channel 必须有镜像清单 URL');
        final String fileName = url!.split('/').last;
        expect(
          frozenHibikiManifests,
          isNot(contains(fileName)),
          reason: '$channel 的镜像读的是 $fileName——'
              '这是老 Hibiki 客户端编译进包里的 URL，本体读它就会两族互相覆盖，'
              '老用户从此更新不到迁移桥包',
        );
        expect(
          fileName.contains('mycomic'),
          isTrue,
          reason: '$channel 的清单名 $fileName 认不出产品族',
        );
      }
    });

    test('产品族后缀非空，且不等于「无后缀」', () {
      expect(kMyComicManifestSuffix.isNotEmpty, isTrue);
      expect(kMyComicManifestSuffix.startsWith('-'), isTrue);
    });
  });

  group('CI 侧与客户端同族', () {
    test('publish_update_manifest.sh 写的每个清单名都带同一个产品族后缀', () {
      final String script =
          File(p.join(repoRoot.path, 'tool', 'publish_update_manifest.sh'))
              .readAsStringSync();

      // 只看真正的清单名赋值，不做全文 grep——否则脚本里解释性的注释会把守卫喂饱。
      // 限定 `latest-` 开头是为了排除把变量原样透传给子进程的
      // `MANIFEST_FILE="$MANIFEST_FILE"`，那不是在定义文件名。
      //
      // 左边界必须显式排掉 `LEGACY_MANIFEST_FILE=`（BUG-1516 ①b 新增）：那是**故意**
      // 不带族后缀的老清单名，用于把桌面产物镜像回 hibiki 族。没有左边界时子串会把它
      // 当成本条要管的「广告用清单名」判红——本条守的是「客户端读哪个文件」，
      // 镜像写入由下面 `desktopMirror` 一组单独立规矩。
      final List<String> assigned =
          RegExp(r'(?<![A-Z_])MANIFEST_FILE="(latest-[^"]+)"')
              .allMatches(script)
              .map((RegExpMatch m) => m.group(1)!)
              .toList();
      expect(
        assigned.length,
        greaterThanOrEqualTo(3),
        reason: '应至少给 debug/beta/formal 三个通道各定一个清单名，'
            '实际解析到 $assigned',
      );

      final String suffix = RegExp(r'MANIFEST_PRODUCT_SUFFIX="([^"]*)"')
              .firstMatch(script)
              ?.group(1) ??
          '';
      expect(
        suffix,
        kMyComicManifestSuffix,
        reason: 'CI 脚本的产品族后缀与客户端常量必须一致，'
            '否则 CI 写一个文件、客户端读另一个，更新链路整条断掉',
      );

      for (final String name in assigned) {
        expect(
          name.contains(r'${MANIFEST_PRODUCT_SUFFIX}') ||
              name.endsWith('$kMyComicManifestSuffix.json'),
          isTrue,
          reason: '清单名 $name 没带产品族后缀——两族会写同一个文件',
        );
      }
    });

    test('BUG-1516 ①b：跨族镜像只准加桌面资产，绝不写顶层、绝不带 APK', () {
      // 拆族的隔离方向是**按平台**的，不是按整份清单：
      //  * Android 必须隔离——跨包名装不上（INSTALL_FAILED_UPDATE_INCOMPATIBLE）。
      //  * Windows/macOS 必须放行——它们换包名靠安装器覆盖安装，Hibiki 桌面客户端
      //    选中 mycomic-*-windows-setup.exe 装下去**就是**迁移本身，桌面没有桥。
      // 一刀切按文件拆的后果是 BUG-1516：桌面槽位冻在拆族前的包上，被 prune 后 404。
      final String script =
          File(p.join(repoRoot.path, 'tool', 'publish_update_manifest.sh'))
              .readAsStringSync();

      final Iterable<RegExpMatch> legacyNames =
          RegExp(r'LEGACY_MANIFEST_FILE="(latest-[^"]+)"').allMatches(script);
      expect(legacyNames.length, greaterThanOrEqualTo(3),
          reason: '三个通道都该有对应的老清单名，才谈得上镜像');
      for (final RegExpMatch m in legacyNames) {
        expect(
          m.group(1)!.endsWith('$kMyComicManifestSuffix.json'),
          isFalse,
          reason: '老清单名 ${m.group(1)} 带了本体族后缀——那就不是老客户端读的那个文件了',
        );
      }

      // 顶层归桥。抬顶层会让安卓客户端读到本体的 version，而它唯一能选的 APK 还是
      // 桥的旧包——正是 BUG-1481 修掉的跨族错位。
      expect(
        script.contains('ADVERTISE_TOP_LEVEL="false"'),
        isTrue,
        reason: '镜像必须以「只贡献资产」模式写入；一旦漏掉这个开关，'
            '本体的 seq 会把桥清单的顶层顶掉',
      );
      expect(
        RegExp(r'ADVERTISE_TOP_LEVEL="true"').hasMatch(script),
        isFalse,
        reason: '脚本里不该出现让镜像写顶层的分支',
      );

      // 镜像资产集必须是 Windows-only 白名单，且显式排除 APK/IPA/macOS。
      // 钉**整个元组**（右括号收尾），不是子串：子串版拦不住往白名单里加东西。
      expect(
        RegExp(r'suffixes = \("-windows-setup\.exe",\)')
            .hasMatch(script),
        isTrue,
        reason: '镜像的资产白名单必须恰好是 Windows 安装包；my-comic 只发 Windows 包',
      );
    });

    test('debug rolling tag 按产品族分，不再共用历史 tag', () {
      const List<List<String>> workflows = <List<String>>[
        <String>['.github', 'workflows', 'release-desktop.yml'],
      ];

      int assignments = 0;
      for (final List<String> parts in workflows) {
        final File file = File(p.join(repoRoot.path, p.joinAll(parts)));
        expect(file.existsSync(), isTrue, reason: '${file.path} 不存在');
        final String body = file.readAsStringSync();

        // 同样只解析赋值右值，绕开注释。
        for (final RegExpMatch m
            in RegExp(r'ROLLING_DEBUG_TAG=(\S+)').allMatches(body)) {
          assignments++;
          final String tag = m.group(1)!;
          expect(
            tag.contains('mycomic'),
            isTrue,
            reason: '${parts.last} 的 rolling tag 是 $tag——'
                '不带产品族的 tag 会让两族资产挂在同一个 release 上，'
                'prune 按平台取 top N seq 时低 seq 的那一族每次被删光',
          );
        }
      }
      expect(assignments, greaterThanOrEqualTo(2),
          reason: 'desktop workflow 的 windows + publish job 各有 1 处 ROLLING_DEBUG_TAG 赋值；实际 $assignments');
    });
  });
}
