import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/profile/profile_keys.dart';

/// 「漫画新章提醒默认关闭」的一次性偏好重置：升级后的第一次运行把 live 偏好与
/// **每一个 Profile 快照**里的已存值覆盖为关闭；扩展更新提醒的已存值不动；之后再
/// 切换开关正常持久化。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String mangaChapterKey = 'updates_notify_manga_chapter';
  const String mangaExtensionKey = 'updates_notify_manga_extension';

  late FushiDatabase db;
  late PreferencesRepository prefs;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
  });

  tearDown(() async {
    prefs.dispose();
    await db.close();
  });

  Future<int> profileWith(Map<String, bool> prefValues) async {
    final int profileId = await db.insertProfile(
      ProfilesCompanion.insert(
        name: 'Profile $prefValues',
        createdAt: 0,
        updatedAt: 0,
      ),
    );
    for (final MapEntry<String, bool> entry in prefValues.entries) {
      await db.upsertProfileSetting(
        ProfileSettingsCompanion.insert(
          profileId: profileId,
          category: ProfileKeys.categoryPref,
          key: entry.key,
          value: PrefCodec.encode(entry.value),
        ),
      );
    }
    return profileId;
  }

  Future<String?> snapshotValue(int profileId, String key) async {
    final List<ProfileSettingRow> rows = await db.getProfileSettings(profileId);
    for (final ProfileSettingRow row in rows) {
      if (row.category == ProfileKeys.categoryPref && row.key == key) {
        return row.value;
      }
    }
    return null;
  }

  test('live 与每个 Profile 快照的漫画新章开关都覆盖为关闭；扩展值不动', () async {
    await prefs.setPrefs(<String, dynamic>{
      mangaChapterKey: true,
      mangaExtensionKey: false,
    });
    final int older = await profileWith(<String, bool>{
      mangaChapterKey: true,
      mangaExtensionKey: false,
    });
    final int newer = await profileWith(<String, bool>{
      mangaChapterKey: true,
      mangaExtensionKey: true,
    });

    await prefs.settleUpdatesNotifyMangaChapterDefaultOff();

    expect(prefs.getPref(mangaChapterKey), isFalse,
        reason: '升级后的第一次运行强制以新默认为准');
    expect(await snapshotValue(older, mangaChapterKey),
        PrefCodec.encode(false),
        reason: '只改 live 的话，切一次 Profile 旧值就被带回来');
    expect(await snapshotValue(newer, mangaChapterKey),
        PrefCodec.encode(false));

    expect(prefs.getPref(mangaExtensionKey), isFalse,
        reason: '扩展提醒的 live 已存值不重置');
    expect(await snapshotValue(older, mangaExtensionKey),
        PrefCodec.encode(false));
    expect(await snapshotValue(newer, mangaExtensionKey),
        PrefCodec.encode(true));

    expect(
      prefs.getPref(
        PreferencesRepository.updatesNotifyMangaChapterDefaultOffMigratedKey,
      ),
      isTrue,
      reason: '标记与重置值同一次写入，之后不再重跑',
    );
  });

  test('重置之后用户再开启正常持久化；下一次启动不会被改回关闭', () async {
    await prefs.setPrefs(<String, dynamic>{mangaChapterKey: true});
    await prefs.settleUpdatesNotifyMangaChapterDefaultOff();
    expect(prefs.getPref(mangaChapterKey), isFalse);

    await prefs.setPref(mangaChapterKey, true);
    await prefs.settleUpdatesNotifyMangaChapterDefaultOff();
    expect(prefs.getPref(mangaChapterKey), isTrue,
        reason: '标记已落下；用户之后的选择必须保留');

    // 模拟重启：从数据库重新装载后再跑一次迁移。
    await prefs.loadFromDb();
    await prefs.settleUpdatesNotifyMangaChapterDefaultOff();
    expect(prefs.getPref(mangaChapterKey), isTrue);
  });

  test('迁移标记是设备本地键，不随 Profile 快照走', () async {
    final int profileId = await profileWith(<String, bool>{
      mangaChapterKey: true,
    });
    await prefs.settleUpdatesNotifyMangaChapterDefaultOff();

    expect(
      await snapshotValue(
        profileId,
        PreferencesRepository.updatesNotifyMangaChapterDefaultOffMigratedKey,
      ),
      isNull,
      reason: '标记进快照的话，切到老 Profile 会把它删掉、迁移重跑');
    expect(
      ProfileKeys.isExcludedPref(
        PreferencesRepository.updatesNotifyMangaChapterDefaultOffMigratedKey,
      ),
      isTrue,
    );
  });
}
