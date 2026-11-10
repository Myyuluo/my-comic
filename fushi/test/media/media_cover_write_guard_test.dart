// 封面落盘收口守卫（审计 §1-A / BUG-1118 根因固化）。
//
// 「同路径覆盖写封面后必须双键驱逐解码缓存」这条不变量此前靠每个落盘点自觉补
// evictLocalCoverCache——BUG-1118 的三处刮削落盘正是漏补的教训。收口后该不变量
// 由 MediaCoverService.applyCoverFile / applyCoverBytes 结构性保证（写盘与驱逐
// 收在同一函数）。本守卫用源码扫描钉死两件事：
//
// ① evict 只许出现在收口链路里（定义处 / 服务 / 书 override 统一写入口）——
//    新代码不得再手写「写盘 + evict」对，只能改走服务；
// ② 出现「封面目的地派生 + 原始写盘调用」的 lib/ 文件必须引用
//    MediaCoverService.applyCover*（即经收口写盘），白名单外不得裸写封面路径。
//
// 豁免（记录在案）：
// - media_cover_service.dart：收口自身。
// - media/video/video_cover_extractor.dart：导入期首写产线（ffmpeg 子进程直写
//   目标路径），Dart 侧无字节可交给收口，见其库注释。
// - lib/src/sync/**：互联层远端封面（remote_cover_image / remote_cover_cache，
//   协议字段 coverUrl 冻结）是网络缓存，本轮不收编（见 MediaCoverService 类注释）。
//
// ③（BUG-1394 补的覆盖洞）**豁免是逐函数的，不是整文件的**。②/① 都是「同一个
//    文件里同时出现派生 + 裸写」才报，于是「派生点与写盘点跨文件」两边都逃：
//    anime_download_importer.dart 派生了 videoCoverFileName 目的地但自己不写盘
//    （→ ② 的 rawWrite 不命中直接放行），真正的裸 writeAsBytes 在被整文件豁免的
//    video_cover_extractor.dart 里（→ ② 的白名单直接 continue）。结果是给「导入
//    期首写」开的豁免被三个**覆盖写**调用点（番剧下载重放、流媒体换封面、导入
//    弹窗重取）复用，同路径重下后 UI 命中旧解码缓存 = 显示旧图，守卫全绿。
//    这条把豁免收成「白名单文件里**哪些函数**可以裸写」的显式清单：新增裸写函数
//    或把已收口的函数改回裸写都会红。
//
// ④（TODO-2715 补的结构洞）**②/③ 都只在「白名单文件」内部收紧，跨文件那条路仍然
//    敞着**：任意新文件 A 派生封面目的地、交给任意文件 B 裸写，A 没有 rawWrite、
//    B 没有 destMarker，两边都不命中。静态扫描追不了跨文件的路径变量流，所以改守
//    **入口**：`kCoverPathDerivers` 是封面目的地派生点的封闭注册表，新增派生点直接
//    红，评审时必须回答「它把这个路径交给谁写」。每条登记还带一个可证伪的角色断言
//    （收口本体 / 经服务落盘 / 只派生不落盘），登记与实际不符同样红。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/source_guard.dart';
import '../helpers/scan_scale.dart';

/// 封面目的地派生标记：三岛目录/文件名的唯一派生入口。
final RegExp kCoverDestMarker = RegExp(
    r'videoCoverFileName\(|videoCoversDirectory\(|gameCoversDirectory\(|VideoStorage\.coversDir\(');

/// 原始写盘调用（对文件的写/拷/换名）。
final RegExp kRawWrite =
    RegExp(r'writeAsBytes\(|\.copy\(|\.rename\(|openWrite\(');

/// 「经收口落盘」的判据：app 的 `MediaCoverService.applyCover*`，或引擎的
/// writer 本体 `writeCoverBytesAtomically` / `writeCoverBytesIfAbsent` /
/// `copyCoverFileAtomically` / `publishStagedCoverFile`（前者是后者的薄委派；
/// 写盘→驱逐的结构在 writer 里，见 cover_file_writer.dart；第四个是外部进程
/// staged 文件的发布口，BUG-2496；`writeCoverBytesIfAbsent` 是本地图源生成封面
/// 的「绝不覆盖」发布口）。
bool _viaCoverSink(String maskedSrc) =>
    maskedSrc.contains('MediaCoverService.applyCover') ||
    maskedSrc.contains('writeCoverBytesAtomically(') ||
    maskedSrc.contains('writeCoverBytesIfAbsent(') ||
    maskedSrc.contains('copyCoverFileAtomically(') ||
    maskedSrc.contains('publishStagedCoverFile(');

/// 一个「封面目的地派生点」文件在收口体系里的角色（TODO-2715 ③）。
enum CoverDeriverRole {
  /// 收口本体：`MediaCoverService` 自己，写盘与驱逐在同一函数里。
  sink,

  /// 派生目的地并**自己写**：必须经 `MediaCoverService.applyCover*`。
  writesViaService,

  /// 只派生路径不写盘（读取 / 展示 / 删除 / 交给收口去写）：文件内不得出现裸写。
  derivesPathOnly,

  /// 派生了封面目的地，但文件内的裸写属于**别的资产**（上传的视频本体、字幕
  /// sidecar 等），封面本身仍交给收口或别的文件去写。
  ///
  /// 为什么需要这一档：分类是**逐文件**的（「这个文件里有没有裸写」），而一个文件
  /// 完全可以既派生封面目录、又因为别的职责而搬运非封面文件——`derivesPathOnly` 对
  /// 它是假的，`writesViaService` 也是假的，硬塞进任一档都会把登记变成谎话。
  ///
  /// 这一档**不是**放行：它必须在 [kNonCoverRawWriters] 里逐函数列出允许裸写的函数
  /// 名，多一个少一个都红——与 BUG-1394 给白名单文件收的那份逐函数名单同一套判据。
  rawWritesNonCoverAssets,
}

/// [CoverDeriverRole.rawWritesNonCoverAssets] 各文件里**允许**裸写的函数全名单。
///
/// manga-only shell（ff3f2df0）移除了视频 / 游戏 / 互联视频域；当前没有文件以
/// `rawWritesNonCoverAssets` 角色登记。保留空表：新增登记仍需逐函数列名。
const Map<String, Set<String>> kNonCoverRawWriters = <String, Set<String>>{};

/// **封面目的地派生点的完整注册表**（TODO-2715 ③）。
///
/// 为什么需要它 —— 旧判据的结构性洞：②「派生 + 裸写」要求两者**在同一个文件**才算
/// 违规，于是把派生点和写盘点拆到两个文件，两边都不命中。BUG-1394 已经在**白名单
/// 文件内部**把豁免收成逐函数，但「任意新文件 A 派生目的地、交给任意文件 B 裸写」
/// 这条路径当时仍然是敞开的：A 没有 rawWrite，B 没有 destMarker。
///
/// 静态扫描追不了跨文件的路径变量流，所以这里改守**入口**：能派生封面目的地的文件
/// 是一个封闭集合，新增一个就红，评审时必须回答「它把这个路径交给谁写？」。
/// 每条登记同时是一条可证伪断言（见下面的三条角色断言），不是一句散文。
///
/// manga-only shell（ff3f2df0）移除了 `kCoverDestMarker` 匹配的视频 / 游戏封面
/// 目的地派生点；书架持久封面缓存按 bookKey 落在 Program state，不使用这些派生
/// 函数，因此当前注册表为空。新增任何封面目的地派生点仍必须登记。
const Map<String, (CoverDeriverRole, String)> kCoverPathDerivers =
    <String, (CoverDeriverRole, String)>{};


/// [path] 里出现裸写调用的函数名集合（判据与 BUG-1394 的逐函数名单同一套：
/// 先等长掩码注释，再按「缩进 ≤2 的声明行」归属行到函数）。
Set<String> _rawWriteFunctionsIn(String path) {
  final RegExp declaration =
      RegExp(r'^ {0,2}(?:static )?(?:[\w<>?,]+ )+(\w+)\s*[({]');
  final List<String> lines =
      maskComments(File(path).readAsStringSync()).split('\n');
  final Set<String> found = <String>{};
  String current = '<file-scope>';
  for (final String line in lines) {
    final RegExpMatch? decl = declaration.firstMatch(line);
    if (decl != null) current = decl.group(1)!;
    if (kRawWrite.hasMatch(line)) found.add(current);
  }
  return found;
}

void main() {
  // 封面写盘的两半现在跨两棵树：app `lib/`（收口 API、UI 派生点）与
  // `../packages/fushi_engine/lib`（writer 本体、ffmpeg 抽帧、库服务）。只扫一棵
  // 就会让另一棵上的登记全部「dead」、新裸写点全部漏网。
  final List<Directory> scanRoots = <Directory>[
    Directory('lib'),
    Directory('../packages/fushi_engine/lib'),
  ];

  List<File> dartFiles() => <File>[
        for (final Directory root in scanRoots)
          ...root
              .listSync(recursive: true)
              .whereType<File>()
              .where((File f) => f.path.endsWith('.dart')),
      ]..sort((File a, File b) => a.path.compareTo(b.path));

  String norm(String path) => p.split(path).join('/');

  test('扫描规模哨兵：lib/ 与 fushi_engine/lib 确实被枚举到了', () {
    expectScanScale(dartFiles().length,
        what: 'lib/ + ../packages/fushi_engine/lib 下的 .dart',
        atLeast: 850, measured: 1058);
    expect(
      dartFiles().any((File f) =>
          norm(f.path).endsWith('fushi_engine/lib/media/cover_file_writer.dart')),
      isTrue,
      reason: '引擎树没被枚举到：写盘本体在那边，漏扫等于守卫真空',
    );
  });

  test('evictLocalCoverCache 只许出现在收口链路（新落盘点必须改走 MediaCoverService）', () {
    // 定义处 + 服务 + 书 override 统一写入口（setOverrideThumbnail* 的历史收口，
    // MediaCoverService.applyBookCoverOverride 薄路由到它）。
    const Set<String> allowed = <String>{
      'lib/src/utils/cover_image.dart',
      'lib/src/media/media_cover_service.dart',
      'lib/src/media/media_source.dart',
      // 引擎 writer 的写后驱逐钩子在这里绑到 evictLocalCoverCache：它就是收口链路
      // 的 Flutter 半边，不是散点手补。
      'lib/src/engine_bindings.dart',
    };
    final List<String> offenders = <String>[];
    for (final File f in dartFiles()) {
      final String path = norm(f.path);
      if (allowed.contains(path)) continue;
      if (f.readAsStringSync().contains('evictLocalCoverCache(')) {
        offenders.add(path);
      }
    }
    expect(offenders, isEmpty,
        reason: '这些文件手写了 evictLocalCoverCache——封面「写盘→驱逐」必须走 '
            'MediaCoverService.applyCoverFile/applyCoverBytes 收口，不得再散点手补：\n'
            '${offenders.join('\n')}');
  });

  test('封面目的地派生点是封闭集合（跨文件「派生在 A、裸写在 B」的结构洞，TODO-2715）', () {
    final Map<String, String> actual = <String, String>{};
    for (final File f in dartFiles()) {
      final String path = norm(f.path);
      final String src = maskComments(f.readAsStringSync());
      if (!kCoverDestMarker.hasMatch(src)) continue;
      // 「经收口」= app 的 MediaCoverService.applyCover* 或引擎的 writer 本体
      // （前者只是后者的薄委派；引擎里的调用方没有 MediaCoverService 可用）。
      actual[path] = _viaCoverSink(src)
          ? 'viaService'
          : (kRawWrite.hasMatch(src) ? 'rawWrite' : 'pathOnly');
    }

    final List<String> unregistered = actual.keys
        .where((String p) => !kCoverPathDerivers.containsKey(p))
        .toList(growable: false);
    expect(unregistered, isEmpty,
        reason: '新的封面目的地派生点未登记。派生点是收口体系的入口：'
            '「派生在 A、裸写在 B」正是 BUG-1394 那类漏网形态，而逐文件的'
            '「派生 + 裸写同文件」判据对它零覆盖。请把它加进 kCoverPathDerivers '
            '并写清它把路径交给谁写：\n${unregistered.join('\n')}');

    final List<String> dead = kCoverPathDerivers.keys
        .where((String p) => !actual.containsKey(p))
        .toList(growable: false);
    expect(dead, isEmpty,
        reason: '这些登记项已经不再派生封面目的地——理由与代码脱节的登记等于一张'
            '不会被审的通行证，删掉它：\n${dead.join('\n')}');

    // 角色断言：每条登记都必须是可证伪的，而不是一句散文。
    final List<String> roleViolations = <String>[];
    kCoverPathDerivers.forEach((String path, (CoverDeriverRole, String) entry) {
      final String? state = actual[path];
      if (state == null) return; // 已由 dead 断言报出。
      switch (entry.$1) {
        case CoverDeriverRole.sink:
          if (state != 'rawWrite') {
            roleViolations.add('$path: 登记为收口本体，却不再自己写盘（实际 $state）');
          }
        case CoverDeriverRole.writesViaService:
          if (state != 'viaService') {
            roleViolations.add('$path: 登记为「经 MediaCoverService 落盘」，实际 $state——'
                '要么它改回裸写了，要么它已经不写盘、该改登记为 derivesPathOnly');
          }
        case CoverDeriverRole.derivesPathOnly:
          if (state != 'pathOnly') {
            roleViolations.add('$path: 登记为「只派生路径不落盘」，实际 $state——'
                '它开始写盘了，必须经 MediaCoverService.applyCover*');
          }
        case CoverDeriverRole.rawWritesNonCoverAssets:
          if (state != 'rawWrite') {
            roleViolations.add('$path: 登记为「裸写的是非封面资产」，实际 $state——'
                '它已经不裸写了（该改 derivesPathOnly），或改走了收口（改 '
                'writesViaService）');
          }
          // 逐函数名单：这一档的整个正当性建立在「裸写的那几个函数搬的不是封面」
          // 上，所以函数集合必须与登记完全一致，多一个少一个都红。
          final Set<String>? allowed = kNonCoverRawWriters[path];
          if (allowed == null) {
            roleViolations.add('$path: 登记为 rawWritesNonCoverAssets 却没有在 '
                'kNonCoverRawWriters 里列出允许裸写的函数——没有名单的豁免等于'
                '整文件放行');
          } else {
            final Set<String> found = _rawWriteFunctionsIn(path);
            if (found.length != allowed.length ||
                !found.containsAll(allowed)) {
              roleViolations.add(
                  '$path: 裸写函数与登记名单不符（实际=$found 登记=$allowed）——'
                  '新增的裸写函数如果碰的是封面，必须改走 '
                  'MediaCoverService.applyCover*');
            }
          }
      }
    });
    expect(roleViolations, isEmpty, reason: roleViolations.join('\n'));
  });

  test('封面目的地写盘必须经 MediaCoverService.applyCover*（白名单外禁裸写）', () {
    final RegExp destMarker = kCoverDestMarker;
    final RegExp rawWrite = kRawWrite;
    // 注释（行注释 / doc / 块注释）里的提法不算调用：先做共享词法掩码再匹配，
    // 否则「见 VideoStorage.coversDir()」这类文档引用会误报。TODO-2477：旧写法是
    // 删除式 `replaceAll(RegExp(r'//.*$'), '')`，块注释与串里的 `//` 两个方向都错。
    const Set<String> allowed = <String>{
      // 收口自身。
      'lib/src/media/media_cover_service.dart',
    };
    final List<String> offenders = <String>[];
    for (final File f in dartFiles()) {
      final String path = norm(f.path);
      if (allowed.contains(path)) continue;
      // rawWritesNonCoverAssets 档：这些文件确实派生了封面目的地，但裸写搬的是
      // 别的资产（上传的视频本体、字幕 sidecar、torrent metainfo）。它们的边界不是
      // 在这里整文件放行，而是由 kNonCoverRawWriters 的**逐函数**名单 + 上面的角色
      // 断言（实际裸写函数集合必须与登记完全一致）钉死——新增一个裸写函数就红。
      // 在这里再报一次，只会逼人把文件塞进上面那张没有函数粒度的 allowed，反而更松。
      if (kCoverPathDerivers[path]?.$1 ==
          CoverDeriverRole.rawWritesNonCoverAssets) {
        continue;
      }
      // 互联层远端封面本轮不收编（协议 coverUrl 冻结，W 系列另册处理）。
      if (path.startsWith('lib/src/sync/') ||
          path.startsWith('../packages/fushi_engine/lib/sync/')) {
        continue;
      }
      final String src = maskComments(f.readAsStringSync());
      if (!destMarker.hasMatch(src)) continue;
      if (!rawWrite.hasMatch(src)) continue;
      if (_viaCoverSink(src)) continue;
      offenders.add(path);
    }
    expect(offenders, isEmpty,
        reason: '这些文件推导了封面目的地路径且有原始写盘调用，但没有经 '
            'MediaCoverService.applyCoverFile/applyCoverBytes 收口（BUG-1118 '
            '的「落盘后忘 evict」正是这么回归的）：\n${offenders.join('\n')}');
  });

  test('白名单文件的裸写豁免逐函数登记（跨文件派生+写盘的覆盖洞，BUG-1394）', () {
    // 白名单文件里**允许**裸写封面的函数全名单。空 = 该文件已无裸写。
    // 新增裸写函数、或把已收口的函数改回裸 writeAsBytes，都会让本用例红。
    const Map<String, Set<String>> allowedRawWriters = <String, Set<String>>{
      // app 收口 API 已是薄委派，本文件不该再有任何裸写。
      'lib/src/media/media_cover_service.dart': <String>{},
      // 收口实现本体（.tmp 写 / copy + rename + 驱逐）在引擎 writer 里。
      '../packages/fushi_engine/lib/media/cover_file_writer.dart': <String>{
        'writeCoverBytesAtomically',
        // 本地图源生成封面：独占创建 + 写字节 + 驱逐，绝不覆盖已有封面。
        'writeCoverBytesIfAbsent',
        'copyCoverFileAtomically',
        // BUG-2496：ffmpeg 写 staged 文件后由这里校验 + rename 发布 + 驱逐。
        'publishStagedCoverFile',
      },
    };
    final RegExp rawWrite =
        RegExp(r'writeAsBytes\(|\.copy\(|\.rename\(|openWrite\(');
    // 顶层声明 / 类成员声明的行首标识（`static Future<void> applyCoverBytes({`、
    // `Future<String?> downloadVideoCoverToPath({` 等）：缩进 ≤2 且缩进之后**立刻**
    // 是标识符，取 `(` / `{` 前的最后一个标识符为函数名。缩进阈值把函数体里的
    // `if (...) {` / `} catch (_) {` 这类控制流挡在外面（它们缩进 ≥4，且行首不是
    // 「类型 空格 名字」的形状）。
    final RegExp declaration =
        RegExp(r'^ {0,2}(?:static )?(?:[\w<>?,]+ )+(\w+)\s*[({]');

    allowedRawWriters.forEach((String path, Set<String> allowed) {
      // 先等长掩码再按行切：块注释与串里的 `//` 都掩得掉，且列宽与原文一致，
      // 所以 declaration 正则仍能在掩码行上正确匹配（代码本身原样保留）。
      final List<String> lines =
          maskComments(File(path).readAsStringSync()).split('\n');
      final Set<String> found = <String>{};
      String current = '<file-scope>';
      for (final String line in lines) {
        final RegExpMatch? decl = declaration.firstMatch(line);
        if (decl != null) current = decl.group(1)!;
        if (rawWrite.hasMatch(line)) {
          found.add(current);
        }
      }
      expect(found, allowed,
          reason: '$path 里的裸写封面函数与登记名单不符。豁免是逐函数的：'
              '「导入期首写」的理由只对 ffmpeg 子进程写盘成立，Dart 侧有字节的路'
              '（被覆盖写场景跨文件复用）必须走 MediaCoverService.applyCoverBytes。\n'
              '实际=$found 登记=$allowed');
    });
  });

  test('收口方法本体存在且包含「写盘→驱逐」结构', () {
    final String service = maskComments(
        File('lib/src/media/media_cover_service.dart').readAsStringSync());
    expect(service.contains('applyCoverFile'), isTrue);
    expect(service.contains('applyCoverBytes'), isTrue);
    expect(service.contains('copyCoverFileAtomically('), isTrue);
    expect(service.contains('writeCoverBytesAtomically('), isTrue);
    // 写盘→驱逐的结构在引擎 writer：四个入口各自发布成功后必须驱逐 dest。
    final String writer = maskComments(
        File('../packages/fushi_engine/lib/media/cover_file_writer.dart')
            .readAsStringSync());
    expect(
        RegExp(r'await evictImageCacheForFile\(dest\);').allMatches(writer).length,
        4,
        reason: '引擎 writer 的四个入口都必须在发布之后驱逐 destPath 的解码缓存'
            '（BUG-1118 的不变量搬进引擎后就住在这里）');
    // BUG-2496：「落盘的必须是完整可解码图片」的判据也只住在这三个入口——字节路查
    // isDecodableImageBytes，文件路（copy / staged 发布）查 isDecodableImageFile；
    // 判据放调用点各写一遍正是当年漏掉 ffmpeg 抽帧 / PDF / SRT 封面三处的形状。
    expect(
        RegExp(r'if \(!isDecodableImageBytes\(bytes\)\)').hasMatch(writer), isTrue,
        reason: 'writeCoverBytesAtomically 必须先拒收非图片/截断字节');
    expect(
        RegExp(r'if \(!await isDecodableImageFile\(source\)\)').hasMatch(writer),
        isTrue,
        reason: 'copyCoverFileAtomically 必须先校验源文件是完整图片');
    expect(
        RegExp(r'if \(!await isDecodableImageFile\(staged\)\)').hasMatch(writer),
        isTrue,
        reason: 'publishStagedCoverFile 必须先校验 staged 文件是完整图片');
    // 钩子在 app 侧必须绑到双键 evict（不是整表 clear——那是删除路的锁释放提示）。
    final String bindings =
        maskComments(File('lib/src/engine_bindings.dart').readAsStringSync());
    expect(bindings.contains('evictImageCacheForFile = _evictImageCacheForFile;'),
        isTrue);
    expect(
        RegExp(r'_evictImageCacheForFile\(File file\) =>\s*evictLocalCoverCache\(file\.path\);')
            .hasMatch(bindings),
        isTrue,
        reason: 'app 的写后驱逐钩子必须是 evictLocalCoverCache 的双键 evict');
  });
}
