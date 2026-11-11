import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';

/// ADR 0024 的干净切换：MyComic 发布资产统一使用 `mycomic-` 前缀。
///
/// 旧 `fushi-` / `hibiki-` 资产不再属于本产品族，也不做兼容；旧版客户端无法自动
/// 发现新资产，需要手动更新/重装一次。本文件保留资产选择的架构正确性契约。
void main() {
  const String version = '1.0.0';

  group('MyComic 资产族', () {
    test('合成名全部使用 mycomic- 前缀并通过产品族判据', () {
      final List<String> names = synthesizeStableAssetNames(version);
      expect(names, isNotEmpty);
      for (final String name in names) {
        expect(name, startsWith('mycomic-$version-'));
        expect(assetBelongsToThisProduct(name), isTrue, reason: name);
      }
    });

    test('旧 fushi- / hibiki- / 无前缀资产一律拒绝', () {
      for (final String name in <String>[
        'fushi-1.0.0-windows-setup.exe',
        'fushi-1.0.0-arm64-v8a.apk',
        'hibiki-1.0.0-arm64-v8a.apk',
        'bridge-1.0.0-arm64-v8a.apk',
        'app-arm64-v8a-release.apk',
      ]) {
        expect(assetBelongsToThisProduct(name), isFalse, reason: name);
      }
    });

    test('旧客户端的产品族白名单看不到 MyComic 资产（干净切换）', () {
      // 模拟仍在野的 Fushi 客户端：只认 `fushi-` 前缀。
      bool legacyFushiSees(String name) => name.startsWith('fushi-');
      for (final String name in synthesizeStableAssetNames(version)) {
        expect(legacyFushiSees(name), isFalse, reason: name);
      }
    });
  });

  group('当前客户端：架构选择正确且不受资产顺序影响', () {
    const Map<String, List<String>> deviceAbis = <String, List<String>>{
      'arm64 设备': <String>['arm64-v8a', 'armeabi-v7a', 'armeabi'],
      'arm32 设备': <String>['armeabi-v7a', 'armeabi'],
      'x86_64 设备': <String>['x86_64', 'x86', 'armeabi-v7a', 'armeabi'],
    };

    Future<UpdateAsset?> pick(List<String> names, List<String> abis) =>
        AndroidUpdater(abiProvider: () async => abis)
            .selectAsset(<Map<String, dynamic>>[
          for (final String n in names)
            <String, dynamic>{
              'name': n,
              'browser_download_url': 'https://example.invalid/$n',
            },
        ]);

    List<String> formalAssets() => <String>[
          ...synthesizeStableAssetNames(version),
          'bridge-$version-arm64-v8a.apk',
          'fushi-$version-arm64-v8a.apk',
        ];

    test('三类设备各挑到本架构的 MyComic 包，桥包/旧名在场也不选', () async {
      expect(
        (await pick(formalAssets(), deviceAbis['arm64 设备']!))!.name,
        'mycomic-$version-arm64-v8a.apk',
      );
      expect(
        (await pick(formalAssets(), deviceAbis['arm32 设备']!))!.name,
        'mycomic-$version-armeabi-v7a.apk',
      );
      expect(
        (await pick(formalAssets(), deviceAbis['x86_64 设备']!))!.name,
        'mycomic-$version-x86_64.apk',
      );
    });

    test('资产倒序喂入不改变架构选择', () async {
      final List<String> reversed =
          formalAssets().reversed.toList(growable: false);
      expect(
        (await pick(reversed, deviceAbis['arm64 设备']!))!.name,
        'mycomic-$version-arm64-v8a.apk',
      );
    });

    test('有分架构包但没有本机这一档 → 返回 null，不塞错架构', () async {
      expect(await pick(synthesizeStableAssetNames(version), <String>['riscv64']),
          isNull);
    });

    test('universal 单包（debug 通道）仍走兜底', () async {
      final UpdateAsset? picked = await AndroidUpdater(
        abiProvider: () async => <String>[],
      ).selectAsset(<Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'mycomic-1.0.0-debug.1-abc1234-debug.apk',
          'browser_download_url': 'https://example.invalid/u.apk',
        },
      ], channel: UpdateChannel.debug);
      expect(picked!.name, 'mycomic-1.0.0-debug.1-abc1234-debug.apk');
    });
  });
}
