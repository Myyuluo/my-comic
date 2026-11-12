import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Ticket 05 接线守卫：全新漫画-only schema + 旧库/旧应用快照入口不再接线。
///
/// 这些是**结构性**不变量（换库文件名、只建子集、旧备份入口不再接线），行为测试
/// 覆盖不到「入口又被悄悄接回来」这类回归，故在源码语料层钉死。
void main() {
  String read(String relativePath) {
    final File file = File(relativePath);
    expect(file.existsSync(), isTrue, reason: '守卫目标文件应存在：$relativePath');
    return file.readAsStringSync();
  }

  const String databasePath =
      '../packages/my_comic_core/lib/src/database/database.dart';

  test('schema 从 v1 重新起算，且没有 MyComic 的迁移阶梯', () {
    final String database = read(databasePath);
    expect(database.contains('const int kMyComicSchemaVersion = 5;'), isTrue);
    expect(
      database.contains('int get schemaVersion => kMyComicSchemaVersion;'),
      isTrue,
    );
    // 旧阶梯的特征：按版本号递增的 `if (from < N)` 分支。全部删除。
    expect(
      RegExp(r'if \(from < \d+\)').hasMatch(database),
      isFalse,
      reason: 'MyComic v1–v118 迁移阶梯必须已删除，不得保留旧 schema 兼容路径',
    );
    expect(
      database.contains('await m.createAll()'),
      isFalse,
      reason: 'onCreate 只能建漫画-only 子集，禁止 createAll 把旧表建回来',
    );
  });

  test('应用只打开 my_comic.db，不识别旧库名', () {
    final String database = read(databasePath);
    expect(
      database.contains(
        "const String kMyComicDatabaseFileName = 'my_comic.db';",
      ),
      isTrue,
    );
    expect(
      database.contains(
        'const String myComicDatabaseFileName = kMyComicDatabaseFileName;',
      ),
      isTrue,
    );
    expect(
      database.contains("File(p.join(dbDirectory, myComicDatabaseFileName))"),
      isTrue,
    );
    // 旧库名不得再参与开库/残留识别路径。
    expect(database.contains('_rejectPreRenameDatabase'), isFalse);
    expect(database.contains('legacyHibikiDatabaseFileName'), isFalse);
    expect(database.contains('myComicLegacyDatabaseFileName'), isFalse);
  });

  test('旧应用快照导入/导出入口不再接线', () {
    final String main = read('lib/main.dart');
    expect(
      main.contains('BackupImportOverlayView'),
      isFalse,
      reason: '启动根不得再挂 MyComic 备份导入遮罩',
    );
    expect(main.contains('backup_import_overlay_view.dart'), isFalse);

    final String settings = read('lib/src/settings/settings_schema.dart');
    expect(
      settings.contains('buildSyncBackupDestination()'),
      isFalse,
      reason: '设置页不得再暴露 MyComic 备份导入/导出分类',
    );

    final String ctl = read(
      'lib/src/platform/desktop/ctl/ctl_data_routes.dart',
    );
    expect(
      ctl.contains('..._backupRoutes('),
      isFalse,
      reason: '桌面控制通道不得再注册 MyComic 备份导入/导出路由',
    );
  });

  test('启动期不恢复 MyComic 备份、不读非漫画表', () {
    final String appModel = read('lib/src/models/app_model.dart');
    expect(
      appModel.contains('BackupRestoreService.recoverPendingRestore'),
      isFalse,
    );
    expect(
      appModel.contains('dictRepo.loadFromDb()'),
      isFalse,
      reason: 'dictionary_metadata 不在漫画-only schema 里',
    );
    expect(
      appModel.contains('prefsRepo.settleSrsMiningTargetInstallDefault('),
      isFalse,
      reason: '该方法会读 mined_sentences / pending_mine_queue',
    );
    expect(
      appModel.contains('unawaited(_warmUpSearchAfterFirstFrame())'),
      isFalse,
    );
  });
}
