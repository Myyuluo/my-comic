import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_comic/src/storage/app_paths.dart';
import 'package:my_comic/src/storage/content_root_switch.dart';
import 'package:my_comic/src/storage/content_root_validation.dart';

/// Ticket 08：切换 Content root 只在新位置创建 `downloads` / `autobackup` /
/// `local` 三个空文件夹，不移动/复制任何旧文件，也不重基库内路径。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory installDir;
  late Directory programState;
  late Directory defaultContent;
  late Directory oldContent;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('content_root_switch_');
    installDir = Directory(p.join(tmp.path, 'install'))
      ..createSync(recursive: true);
    programState = Directory(p.join(tmp.path, 'userdata'))
      ..createSync(recursive: true);
    defaultContent = Directory(p.join(tmp.path, 'Documents', 'MyComic'))
      ..createSync(recursive: true);
    oldContent = Directory(p.join(tmp.path, 'OldContent'))
      ..createSync(recursive: true);
  });

  tearDown(() {
    AppPaths.debugTestEnvironment = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ContentRootSwitch switcher() => ContentRootSwitch(
    programStateRoot: programState,
    defaultContentRoot: defaultContent,
    executablePath: p.join(installDir.path, 'my_comic.exe'),
  );

  test('切换只创建三个空文件夹，不移动/复制旧文件', () async {
    final File oldChapter = File(
      p.join(
        oldContent.path,
        'downloads',
        'Source',
        'Manga',
        'Ch 1',
        '001.jpg',
      ),
    )..createSync(recursive: true);
    oldChapter.writeAsStringSync('old page bytes');
    // 旧 Local source root（更名前）：切换后原地保留，绝不迁移。
    final File oldLocalPage = File(
      p.join(oldContent.path, 'localcomic', 'Old Manga', 'Ch 1', '001.jpg'),
    )..createSync(recursive: true);
    oldLocalPage.writeAsStringSync('old local page');
    final Directory newContent = Directory(p.join(tmp.path, 'NewContent'));

    final ContentRootSwitchResult result = await switcher().switchTo(
      newContent.path,
    );

    expect(result.succeeded, isTrue);
    expect(result.failure, isNull);
    expect(result.contentRoot!.path, p.canonicalize(newContent.path));

    for (final String name in <String>[
      'downloads',
      'autobackup',
      'local',
    ]) {
      final Directory dir = Directory(p.join(newContent.path, name));
      expect(dir.existsSync(), isTrue, reason: '$name 必须存在');
      expect(dir.listSync(), isEmpty, reason: '切换不得复制旧文件到 $name');
    }
    expect(
      Directory(p.join(newContent.path, 'localcomic')).existsSync(),
      isFalse,
      reason: '更名后不再创建旧 localcomic',
    );
    // 旧文件原地保留：没有搬移、没有复制、没有删除。
    expect(oldChapter.existsSync(), isTrue);
    expect(oldChapter.readAsStringSync(), 'old page bytes');
    expect(oldLocalPage.existsSync(), isTrue, reason: '旧 localcomic 不得删除');
    expect(oldLocalPage.readAsStringSync(), 'old local page');
    expect(
      File(
        p.join(
          newContent.path,
          'downloads',
          'Source',
          'Manga',
          'Ch 1',
          '001.jpg',
        ),
      ).existsSync(),
      isFalse,
      reason: '旧内容不得出现在新 Content root',
    );
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(AppPaths.contentRootPrefKey),
      p.canonicalize(newContent.path),
    );
  });

  test('切回默认 Content root 时清除 content_root 偏好', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppPaths.contentRootPrefKey: oldContent.path,
    });

    final ContentRootSwitchResult result = await switcher().switchTo(
      defaultContent.path,
    );

    expect(result.succeeded, isTrue);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppPaths.contentRootPrefKey), isNull);
    expect(
      Directory(p.join(defaultContent.path, 'downloads')).existsSync(),
      isTrue,
    );
  });

  test('切换到同一位置是幂等的，不清空已有内容', () async {
    final File existing = File(p.join(oldContent.path, 'downloads', 'keep.txt'))
      ..createSync(recursive: true);
    existing.writeAsStringSync('keep');

    final ContentRootSwitchResult result = await switcher().switchTo(
      oldContent.path,
    );

    expect(result.succeeded, isTrue);
    expect(existing.existsSync(), isTrue);
    expect(existing.readAsStringSync(), 'keep');
    for (final String name in <String>[
      'downloads',
      'autobackup',
      'local',
    ]) {
      expect(Directory(p.join(oldContent.path, name)).existsSync(), isTrue);
    }
  });

  test('拒绝相对路径，且不改变偏好', () async {
    final ContentRootSwitchResult result = await switcher().switchTo(
      p.join('relative', 'root'),
    );

    expect(result.succeeded, isFalse);
    expect(result.failure, ContentRootSwitchFailure.notAbsolute);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppPaths.contentRootPrefKey), isNull);
  });

  test('拒绝安装目录、安装目录内部与安装目录的祖先', () async {
    for (final String target in <String>[
      installDir.path,
      p.join(installDir.path, 'data'),
      tmp.path,
    ]) {
      final ContentRootSwitchResult result = await switcher().switchTo(target);
      expect(result.succeeded, isFalse, reason: target);
      expect(
        result.failure,
        ContentRootSwitchFailure.installDirectory,
        reason: target,
      );
    }
  });

  test('拒绝 Program state root 内部的位置', () async {
    for (final String target in <String>[
      programState.path,
      p.join(programState.path, 'content'),
    ]) {
      final ContentRootSwitchResult result = await switcher().switchTo(target);
      expect(result.succeeded, isFalse, reason: target);
      expect(
        result.failure,
        ContentRootSwitchFailure.insideProgramStateRoot,
        reason: target,
      );
    }
  });

  test('切换与启动共用的校验器把不可写目标判为 notWritable', () async {
    final File blocker = File(p.join(tmp.path, 'blocked_validator'))
      ..writeAsStringSync('not a directory');

    final ContentRootValidationFailure? failure =
        await ContentRootTargetValidator(
          programStateRoot: programState,
          executablePath: p.join(installDir.path, 'my_comic.exe'),
        ).validate(p.join(blocker.path, 'candidate'));

    expect(failure, ContentRootValidationFailure.notWritable);
  });

  test('不可写的位置失败，且偏好保持不变', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppPaths.contentRootPrefKey: oldContent.path,
    });
    final File blocker = File(p.join(tmp.path, 'blocked'))
      ..writeAsStringSync('not a directory');

    final ContentRootSwitchResult result = await switcher().switchTo(
      p.join(blocker.path, 'candidate'),
    );

    expect(result.succeeded, isFalse);
    expect(result.failure, ContentRootSwitchFailure.notWritable);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppPaths.contentRootPrefKey), oldContent.path);
  });

  test('切换后 AppPaths 只解析新 Content root，不读旧路径', () async {
    AppPaths.debugTestEnvironment = <String, String>{
      'MYCOMIC_TEST_ROOT': tmp.path,
    };
    final Directory testDefault = Directory(p.join(tmp.path, 'content'))
      ..createSync(recursive: true);
    final Directory newContent = Directory(p.join(tmp.path, 'NewContent'));
    final ContentRootSwitch switcherWithDefault = ContentRootSwitch(
      programStateRoot: programState,
      defaultContentRoot: testDefault,
      executablePath: p.join(installDir.path, 'my_comic.exe'),
    );

    final ContentRootSwitchResult result = await switcherWithDefault.switchTo(
      newContent.path,
    );

    expect(result.succeeded, isTrue);
    final Directory resolved = await AppPaths.contentRootDirectory();
    expect(resolved.path, p.canonicalize(newContent.path));
    final Directory downloads = await AppPaths.downloadsRootDirectory();
    expect(
      downloads.path,
      p.join(p.canonicalize(newContent.path), 'downloads'),
    );
    expect(p.isWithin(oldContent.path, downloads.path), isFalse);
  });
}
