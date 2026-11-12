import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/utils/misc/platform_updater.dart';
import 'package:my_comic/src/utils/misc/update_check_cache.dart';

/// TODO-1024 / BUG-479：更新检查结果缓存的纯单测（不触网络/DB/path_provider）。
///
/// 验证缓存优先 + 后台静默刷新所依赖的核心数据结构契约：
/// - encode/decode roundtrip 无损（命中缓存即时返回，不打网络）；
/// - 任意畸形原始串 → decode 返 null（安全回退「无缓存」走网络，绝不抛错）；
/// - `cachedEntryForChannel` 通道隔离（stable 缓存不被 beta 误用）；
/// - epoch 数值容错（int / num / 缺失）。
void main() {
  group('UpdateCheckCacheEntry encode/decode roundtrip', () {
    test('roundtrip 保真', () {
      const UpdateCheckCacheEntry entry = UpdateCheckCacheEntry(
        lastCheckEpochMs: 1719705600000,
        latestTag: 'v1.2.3',
        htmlUrl: 'https://github.com/owner/repo/releases/tag/v1.2.3',
        channel: UpdateChannel.stable,
      );
      final UpdateCheckCacheEntry? back =
          UpdateCheckCacheEntry.decode(entry.encode());
      expect(back, isNotNull);
      expect(back!.lastCheckEpochMs, entry.lastCheckEpochMs);
      expect(back.latestTag, entry.latestTag);
      expect(back.htmlUrl, entry.htmlUrl);
      expect(back.channel, entry.channel);
      expect(back.repository, entry.repository);
      expect(back.repository, kUpdateCheckSourceRepository);
    });

    test('beta/debug 通道编码进 channel 字段', () {
      for (final UpdateChannel c in UpdateChannel.values) {
        final UpdateCheckCacheEntry e = UpdateCheckCacheEntry(
          lastCheckEpochMs: 0,
          latestTag: '1.0.0-beta.1',
          htmlUrl: '',
          channel: c,
        );
        expect(UpdateCheckCacheEntry.decode(e.encode())?.channel, c);
      }
    });

    test('lastCheckTime 由 epoch 还原（UTC 存、本地读，瞬时相等）', () {
      const int ms = 1719705600000;
      const UpdateCheckCacheEntry e = UpdateCheckCacheEntry(
        lastCheckEpochMs: ms,
        latestTag: 'v1.0.0',
        htmlUrl: '',
        channel: UpdateChannel.stable,
      );
      expect(e.lastCheckTime.millisecondsSinceEpoch, ms);
    });
  });

  group('UpdateCheckCacheEntry.decode 畸形安全回退 null', () {
    test('null / 空串 → null', () {
      expect(UpdateCheckCacheEntry.decode(null), isNull);
      expect(UpdateCheckCacheEntry.decode(''), isNull);
    });

    test('非 JSON → null', () {
      expect(UpdateCheckCacheEntry.decode('not json {'), isNull);
    });

    test('JSON 非对象（数组/标量）→ null', () {
      expect(UpdateCheckCacheEntry.decode('[1,2,3]'), isNull);
      expect(UpdateCheckCacheEntry.decode('42'), isNull);
    });

    test('缺 latestTag / 空 latestTag → null', () {
      expect(
        UpdateCheckCacheEntry.decode(
            '{"channel":"stable","repository":"Myyuluo/my-comic","latestTag":""}'),
        isNull,
      );
      expect(
        UpdateCheckCacheEntry.decode(
            '{"channel":"stable","repository":"Myyuluo/my-comic"}'),
        isNull,
      );
    });

    test('通道名不识别 → null', () {
      expect(
        UpdateCheckCacheEntry.decode(
            '{"channel":"nightly","repository":"Myyuluo/my-comic","latestTag":"v1.0.0"}'),
        isNull,
      );
      expect(
        UpdateCheckCacheEntry.decode(
            '{"repository":"Myyuluo/my-comic","latestTag":"v1.0.0","lastCheckEpochMs":1}'),
        isNull,
        reason: '缺 channel 字段也视作无缓存',
      );
    });

    test('epoch 缺失 → 0；epoch 为 num → 截断为 int', () {
      final UpdateCheckCacheEntry? a = UpdateCheckCacheEntry.decode(
          '{"channel":"stable","repository":"Myyuluo/my-comic","latestTag":"v1.0.0"}');
      expect(a, isNotNull);
      expect(a!.lastCheckEpochMs, 0);

      final UpdateCheckCacheEntry? b = UpdateCheckCacheEntry.decode(
          '{"channel":"stable","repository":"Myyuluo/my-comic","latestTag":"v1.0.0","lastCheckEpochMs":12.0}');
      expect(b, isNotNull);
      expect(b!.lastCheckEpochMs, 12);
    });

    test('htmlUrl 缺失 → 空串', () {
      final UpdateCheckCacheEntry? e = UpdateCheckCacheEntry.decode(
          '{"channel":"beta","repository":"Myyuluo/my-comic","latestTag":"1.0.0-beta.1"}');
      expect(e, isNotNull);
      expect(e!.htmlUrl, '');
    });
  });

  group('更新源隔离（fork vs 旧上游缓存）', () {
    const String legacyUpstreamCache =
        '{"channel":"stable","latestTag":"v3.0.0","lastCheckEpochMs":1719705600000}';

    test('旧上游缓存没有 repository → decode 为 null（不显示 Update 3.x）', () {
      expect(UpdateCheckCacheEntry.decode(legacyUpstreamCache), isNull);
    });

    test('旧上游缓存即使显式带 repo 也不被 fork 使用', () {
      const UpdateCheckCacheEntry upstream = UpdateCheckCacheEntry(
        lastCheckEpochMs: 1719705600000,
        latestTag: 'v3.0.0',
        htmlUrl: 'https://github.com/hajisensai/my_comic/releases/tag/v3.0.0',
        channel: UpdateChannel.stable,
        repository: 'hajisensai/my_comic',
      );
      expect(
        cachedEntryForChannel(
          upstream,
          UpdateChannel.stable,
          repository: kUpdateCheckSourceRepository,
        ),
        isNull,
        reason: '更新源不同 = 无可用缓存，必须联网重新检查 fork release',
      );
    });

    test('fork 缓存命中当前更新源时可用', () {
      const UpdateCheckCacheEntry fork = UpdateCheckCacheEntry(
        lastCheckEpochMs: 1719705600000,
        latestTag: 'v1.0.1',
        htmlUrl: 'https://github.com/Myyuluo/my-comic/releases/tag/v1.0.1',
        channel: UpdateChannel.stable,
      );
      expect(
        cachedEntryForChannel(
          fork,
          UpdateChannel.stable,
          repository: kUpdateCheckSourceRepository,
        ),
        same(fork),
      );
    });
  });

  group('cachedEntryForChannel 通道隔离', () {
    const UpdateCheckCacheEntry stableEntry = UpdateCheckCacheEntry(
      lastCheckEpochMs: 0,
      latestTag: 'v1.0.0',
      htmlUrl: '',
      channel: UpdateChannel.stable,
    );

    test('通道匹配 → 原样返回（命中缓存可乐观显示）', () {
      expect(
        cachedEntryForChannel(stableEntry, UpdateChannel.stable),
        same(stableEntry),
      );
    });

    test('通道不匹配 → null（stable 缓存不被 beta 误用）', () {
      expect(cachedEntryForChannel(stableEntry, UpdateChannel.beta), isNull);
      expect(cachedEntryForChannel(stableEntry, UpdateChannel.debug), isNull);
    });

    test('null 入参 → null', () {
      expect(cachedEntryForChannel(null, UpdateChannel.stable), isNull);
    });
  });
}
