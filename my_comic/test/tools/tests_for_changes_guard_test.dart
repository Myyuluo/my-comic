// 守卫：`tool/tests_for_changes.dart` 这条**推导规则**本身。
//
// ## 它替掉了什么
//
// `docs/agent/fast-workflow.md` 里原来挂着一份手写的「按触发条件加跑」清单
// （该文档已随独立化清理删除，目录枚举批改由 `tool/test_flow/pre_push_selection.dart`
// 的 `kEnumerationGuards` 承载），
// 一共点名 9 个测试。那份表的分类维度是「资产种类」（workflow / 扩展 / 二进制 /
// native），而真实触发面的维度是「哪棵源码树」。两者不对齐的后果是：
// `my_comic/android/` 30+ 条守卫**一条触发规则都没有**、`packages/*/windows` 同样
// 零覆盖、`my_comic/windows/` 60+ 条守卫只被点了 1 个名。改一行
// `my_comic/windows/runner/flutter_window.cpp` 会牵动几十条守卫，清单一条都没提。
// 这是「合入的 PR 把红带进 develop」已发生 3 次的共同根因之一（TODO-2720）。
//
// ## 为什么守卫必须存在
//
// 换成推导规则之后，规则本身成了**代码**，于是它会以代码的方式烂：提取器少认一种
// 写法，输出就静默变少，而少输出的表现形式恰恰是「测试更快跑完了」——没有任何人
// 会去质疑它。所以这条守卫的每一项都是在回答同一个问题：**推导出来的东西还够多吗**。
//
// ## 三层判据，缺一不可
//
// 1. **行为对账**：被替掉的那 9 条手写规则，必须能被推导出来（超集，不是近似）。
// 2. **盲区断言**：原先零覆盖的五棵 native 树，现在每棵都推得出测试。
// 3. **规模哨兵 + 独立枚举**：逐树下界，且下界由一份**与提取器毫无共享代码**的
//    朴素文本扫描独立算出。共用同一个有缺陷的枚举函数会让守卫与被守方在同一处
//    同时失明（`tool/bug.dart` 的 buildRenumberPlan / findResidualRefs 共用
//    repoScanPaths 就是这么瞎的），所以这里的朴素侧只用 `String.contains`，
//    一行都不碰 normalizeRepoPath / extractRepoPathReferences。

// tests-for-changes: my_comic/test/**

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/pre_push_selection.dart';
import '../../tool/tests_for_changes.dart';

void main() {
  final RepoFs fs = RepoFs(locateRepoRoot(Directory.current));
  late final Map<RepoPath, TestTriggerFace> index;

  setUpAll(() {
    index = buildReferenceIndex(fs);
  });

  /// 推导：改了 [changed] 该跑哪些测试（仓库根相对的测试路径）。
  Set<RepoPath> derive(String changed) => selectTestsForChanges(
        changedFiles: <RepoPath>[normalizeChangedPath(changed, fs)],
        index: index,
        fs: fs,
      ).keys.toSet();

  /// 朴素侧：**独立枚举** my_comic/test 下的测试文件，与 listAppTestFiles 无共享代码。
  ///
  /// 故意写成最笨的形态（手写递归 + `String.contains`），这样它不可能和结构化
  /// 提取器在同一个地方出错。它算出来的是下界，结构化侧只能比它多不能比它少。
  List<File> naiveTestFiles() {
    final List<File> out = <File>[];
    void walk(Directory dir) {
      for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
        if (e is Directory) {
          walk(e);
        } else if (e is File && e.path.endsWith('_test.dart')) {
          out.add(e);
        }
      }
    }

    walk(Directory('test'));
    return out;
  }

  /// 朴素侧：源码里逐字出现 `<tree>` 且后面不接标识符字符的测试文件数。
  int naiveTreeMentions(String tree) {
    final RegExp needle = RegExp('${RegExp.escape(tree)}(?![A-Za-z0-9_])');
    int n = 0;
    for (final File f in naiveTestFiles()) {
      if (needle.hasMatch(f.readAsStringSync())) n++;
    }
    return n;
  }

  /// 结构化侧：索引里引用到 [tree] 下任意路径的测试文件数。
  int indexedTreeMentions(String tree) => index.entries
      .where((MapEntry<RepoPath, TestTriggerFace> e) => e.value.referencedPaths
          .any((RepoPath ref) => ref == tree || ref.startsWith('$tree/')))
      .length;

  group('tests_for_changes 推导规则', () {
    test('索引规模哨兵：扫描面不得塌掉', () {
      // 独立化清理删除了大量非漫画测试；实测基线见 reason。
      expect(index.length, greaterThanOrEqualTo(800),
          reason: 'my_comic/test 下应有 900+ 个 *_test.dart（实测 932）；'
              '数量塌掉说明 listAppTestFiles 的枚举坏了，'
              '而坏掉的表现是「推导结果变少」——不会有人自己发现');
      final int withFace =
          index.values.where((TestTriggerFace f) => !f.isEmpty).length;
      expect(withFace, greaterThanOrEqualTo(200),
          reason: '实测 235 个测试文件有可提取的触发面（独立化清理删掉大量上游测试）；'
              '掉到 200 以下说明路径提取器少认了一大类写法');
    });

    test('三遍提取各自都必须活着（合成语料逐遍点名）', () {
      // 为什么不能指望全量下界替这条把关：本仓注释极其详尽，一个用 `p.join`
      // 写路径的守卫，注释里往往**同时**写着含斜杠的那条路径。变异实测里把
      // join 那一遍整个关掉，全量下界与「结构化 ≥ 朴素」两条**全绿**——因为
      // 注释里的斜杠写法把它兜住了。逐遍的存活断言只能用合成语料点名。
      expect(
        extractRepoPathReferences(
          'final File f = '
          "File('../my_comic/windows/runner/flutter_window.cpp');",
          fs,
        ),
        contains('my_comic/windows/runner/flutter_window.cpp'),
        reason: '含斜杠字面量那一遍死了',
      );
      expect(
        extractRepoPathReferences(
          'final Directory d = '
          "Directory(p.join(root.path, 'my_comic', 'windows', 'runner'));",
          fs,
        ),
        contains('my_comic/windows/runner'),
        reason: 'p.join 段链那一遍死了——这段语料里一个斜杠都没有，'
            '只有这一遍认得，而本仓大量 native 守卫正是这么写路径的',
      );
      expect(
        extractRepoPathReferences(
          '// 见 packages/flutter_inappwebview_windows/.../in_app_webview.cpp',
          fs,
        ),
        contains('packages/flutter_inappwebview_windows'),
        reason: '最近祖先回退死了：注释里的 `.../` 省略写法退不到那棵树',
      );
      expect(
        extractRepoPathReferences(
          "expect(listing.contains(r'my_comic/windows/never_built_output'), isTrue);",
          fs,
        ),
        contains('my_comic/windows'),
        reason: '最近祖先回退死了：指向构建产物（磁盘上不存在）的路径整条被丢掉',
      );
    });

    test('原先零触发规则的 native 树，现在每棵都推得出测试', () {
      // 表里每一项在替换前的手写清单里都是**零覆盖**（`my_comic/windows` 只有 1 条）。
      // 下界取实测值的约 80%，只在量级塌掉时才响。
      const Map<String, int> blindSpots = <String, int>{
        'packages/gamepads_windows/windows/gamepad.cpp': 1,
        'packages/flutter_inappwebview_windows/windows/CMakeLists.txt': 1,
        'third_party/desktop_drop/windows/desktop_drop_plugin.cpp': 3,
        'my_comic/windows/runner/flutter_window.cpp': 15,
      };
      final List<String> tooThin = <String>[];
      blindSpots.forEach((String changed, int floor) {
        final int got = derive(changed).length;
        if (got < floor) tooThin.add('$changed → $got 个（下界 $floor）');
      });
      expect(tooThin, isEmpty,
          reason: '这些树曾经完全没有触发规则，PR 改到它们时一条守卫都不会被跑到。'
              '推导结果掉到下界以下说明提取器又瞎了：\n${tooThin.join('\n')}');
    });

    test('逐树规模哨兵：结构化提取不得少于独立朴素扫描', () {
      // 朴素侧只认 `my_comic/android` 这种含斜杠的逐字写法；结构化侧还认
      // `p.join(root, 'my_comic', 'android')`。所以结构化 ≥ 朴素是**恒等式级**的期望，
      // 一旦反过来，就是结构化侧的某一遍扫描坏了。
      const List<String> trees = <String>[
        'my_comic/windows',
        '.github/workflows',
        'packages/flutter_inappwebview_windows',
      ];
      final List<String> regressions = <String>[];
      for (final String tree in trees) {
        final int naive = naiveTreeMentions(tree);
        final int indexed = indexedTreeMentions(tree);
        if (indexed < naive) {
          regressions.add('$tree：结构化 $indexed < 朴素 $naive');
        }
      }
      expect(regressions, isEmpty,
          reason: '结构化提取比「逐字 contains」还少，说明含斜杠字面量那一遍漏了：\n'
              '${regressions.join('\n')}');
    });

    test('逐树规模哨兵：绝对下界（实测值的约 80%）', () {
      const Map<String, int> floors = <String, int>{
        'my_comic/windows': 20,
        '.github/workflows': 6,
        'packages/flutter_inappwebview_windows': 8,
      };
      final List<String> thin = <String>[];
      floors.forEach((String tree, int floor) {
        final int got = indexedTreeMentions(tree);
        if (got < floor) thin.add('$tree：$got < $floor');
      });
      expect(thin, isEmpty, reason: '逐树引用数塌到下界以下：\n${thin.join('\n')}');
    });

    test('声明的 tests-for-changes glob 必须匹配到真实文件', () {
      // 声明是唯一「人写」的部分，所以它是唯一会哑掉的部分。
      // 这条把它的腐烂变成响的：glob 匹配不到任何文件就当场红。
      final String rootPath = fs.root.path.replaceAll('\\', '/');
      const Set<String> skip = <String>{
        '.git',
        '.dart_tool',
        '.worktrees',
        '.codex-test',
        'build',
        'node_modules',
        'Pods',
      };
      final List<String> repoFiles = <String>[];
      void walk(Directory dir) {
        late final List<FileSystemEntity> entries;
        try {
          entries = dir.listSync(followLinks: false);
        } on FileSystemException {
          return;
        }
        for (final FileSystemEntity e in entries) {
          final String name = e.path.replaceAll('\\', '/').split('/').last;
          if (skip.contains(name)) continue;
          if (e is Directory) {
            walk(e);
          } else if (e is File) {
            repoFiles.add(
                e.path.replaceAll('\\', '/').replaceFirst('$rootPath/', ''));
          }
        }
      }

      walk(fs.root);
      expect(repoFiles.length, greaterThanOrEqualTo(4500),
          reason: '仓库文件枚举塌了（独立化清理后实测 4984；清理前上万），'
              '下面的 glob 校验会假绿');

      final List<String> declared = <String>[];
      final List<String> dead = <String>[];
      index.forEach((RepoPath test, TestTriggerFace face) {
        for (final String glob in face.declaredGlobs) {
          declared.add('$test: $glob');
          final RegExp re = globToRegExp(glob);
          if (!repoFiles.any(re.hasMatch)) dead.add('$test: $glob');
        }
      });
      expect(declared, isNotEmpty,
          reason: '一条 `// tests-for-changes:` 声明都没有——'
              '要么机制被删了，要么正则不认了；无论哪种，'
              '运行时自己扫仓库的守卫就又没触发规则了');
      expect(dead, isEmpty,
          reason: '这些声明的 glob 在仓库里匹配不到任何文件，已经是死规则：\n'
              '${dead.join('\n')}');
    });

    test('Dart 源码树的改动不由本工具输出（默认整批兜底）', () {
      expect(isDefaultBatchCoveredChange('my_comic/lib/src/models/app_model.dart'),
          isTrue);
      expect(
          isDefaultBatchCoveredChange('my_comic/test/tools/x_test.dart'), isTrue);
      expect(isDefaultBatchCoveredChange('packages/my_comic_core/lib/src/db.dart'),
          isTrue);
      expect(isDefaultBatchCoveredChange('my_comic/windows/runner/x.cpp'), isFalse,
          reason: 'native 树绝不能被当成「已被整批覆盖」而吞掉');
      expect(
          isDefaultBatchCoveredChange(
              'packages/gamepads_windows/windows/x.cpp'),
          isFalse);
    });

    test('两处硬编码目录名必须仍对得上仓库布局', () {
      // 工具里只有这两组硬编码名字。硬编码本身不是问题，**哑掉**才是：
      // 仓库改了布局而常量没跟上，路径解析会静默退化——容器目录不再被拒，
      // 一次对 `my_comic` 的引用就把整棵树拉进触发面，推导结果从「精准」变成「全跑」。
      for (final RepoPath container in kContainerDirs) {
        final Directory dir = Directory('${fs.root.path}/$container');
        expect(dir.existsSync(), isTrue, reason: '容器目录 $container 不在了');
        final int subDirs =
            dir.listSync(followLinks: false).whereType<Directory>().length;
        expect(subDirs, greaterThanOrEqualTo(5),
            reason: '$container 只剩 $subDirs 个子目录，'
                '它可能已经不再是「装着互不相干多个域」的容器目录');
      }
    });

    test('索引里不得混进构建产物路径（否则索引因机器而异）', () {
      // 本机有 `my_comic/build/windows/x64/...`、CI 的干净 checkout 没有。
      // 一旦这类路径进了索引，本机推导出的测试集就和 CI 的不一样——
      // 这是「本机全绿 CI 红」最难查的一种。
      //
      // 注意这条在**没有构建产物的干净环境**上是平凡通过的（那里本来就没东西可混
      // 进来）；它要抓的正是「在有产物的开发机上」跑出来的那份被污染的索引。
      final List<String> polluted = <String>[];
      index.forEach((RepoPath test, TestTriggerFace face) {
        for (final RepoPath ref in face.referencedPaths) {
          if (ref.split('/').any(kNonSourceDirs.contains)) {
            polluted.add('$test → $ref');
          }
        }
      });
      expect(polluted, isEmpty,
          reason: '这些引用落在构建产物 / 机器本地目录里：\n${polluted.join('\n')}');
    });

    test('存在性判定必须逐段精确大小写（Windows NTFS 大小写不敏感）', () {
      // 直接用 existsSync 时，注释里的「Android/iOS/macOS/Windows/Linux」会让
      // `my_comic/Lib` 在 Windows 上判为存在、在 Linux CI 上判为不存在——
      // 同一份索引两个平台两个样，本机全绿 CI 红。
      expect(fs.exists('my_comic/lib'), isTrue,
          reason: '真实目录必须判存在，否则这条测试在守一个空契约');
      expect(fs.exists('my_comic/Lib'), isFalse, reason: '大小写不匹配必须判不存在');
      expect(fs.exists('my_comic/windows'), isTrue);
      expect(fs.exists('my_comic/Windows'), isFalse);
    });

    test('目录枚举批清单随工具入库且不留死条目', () {
      // 上游清单原挂在 docs/agent/fast-workflow.md；该文档已随独立化清理删除，
      // 清单改为 test_flow/pre_push_selection.dart 的 kEnumerationGuards。这里
      // 守住「清单还有人执行、且没有指向已删除测试的死条目」。
      expect(kEnumerationGuards, isNotEmpty);
      final String rootPath = fs.root.path.replaceAll('\\', '/');
      final List<String> missing = <String>[
        for (final String rel in kEnumerationGuards)
          if (!File('$rootPath/my_comic/$rel').existsSync()) rel,
      ];
      expect(missing, isEmpty,
          reason: 'kEnumerationGuards 里的测试已不存在：\n${missing.join('\n')}');
    });
  });
}
