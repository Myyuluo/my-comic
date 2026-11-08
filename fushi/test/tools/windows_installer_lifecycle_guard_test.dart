import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Ticket 03 守卫：Windows 安装器的安装 / 更新 / 卸载生命周期。
///
/// Inno 脚本在 Dart 运行时之外，无法行为测试；这里按 spec 的 installer seam
/// 做源码守卫，钉住不能在 review 里靠肉眼发现的回归：
///  1. 标准「选择安装位置」页与可写性预检保留；自定义「数据存储位置」页删除。
///  2. `data_root.bootstrap` 在安装脚本与 Dart 侧都不再存在。
///  3. `userdata`（Program state root）不在安装清单 `[Files]` / `[InstallDelete]`，
///     原地覆盖升级不会动它。
///  4. `[UninstallDelete]` 删除 `{app}\userdata` 与回退的
///     `%LOCALAPPDATA%\MyComic\userdata`，但完全不碰 Content root。
void main() {
  final String iss = File('windows/installer/fushi.iss').readAsStringSync();
  final String md3Layout = File(
    'windows/installer/md3_layout.iss',
  ).readAsStringSync();

  /// 取 `[Name]` 段正文（到下一个行首段标签为止）。注释行不以 `[` 开头
  /// （fushi.iss 里有明确约定），所以这个切分是安全的。
  String section(String name) {
    final Match? start = RegExp(
      '^\\[$name\\]',
      multiLine: true,
    ).firstMatch(iss);
    expect(start, isNotNull, reason: '缺少 [$name] 段');
    final int from = start!.end;
    final RegExpMatch? next = RegExp(
      '^\\[',
      multiLine: true,
    ).firstMatch(iss.substring(from));
    return iss.substring(from, next == null ? iss.length : from + next.start);
  }

  /// 只要真正的条目行；注释可以提到任何路径，不能拿它当「会不会删」的证据。
  String entries(String name) => section(name)
      .split(RegExp(r'\r?\n'))
      .where((String line) {
        final String trimmed = line.trimLeft();
        return trimmed.isNotEmpty && !trimmed.startsWith(';');
      })
      .join('\n');

  group('标准安装位置页与可写性预检', () {
    test('保留 Inno 标准选目录页（未被 DisableDirPage 隐藏）', () {
      expect(
        RegExp(r'^DisableDirPage=yes$', multiLine: true).hasMatch(iss),
        isFalse,
        reason: '安装器必须让用户选择安装位置',
      );
      expect(section('Setup').toLowerCase(), contains('defaultdirname='));
    });

    test('NextButtonClick 在选目录页用探针文件预检可写性', () {
      expect(iss, contains('function InstallDirWritable'));
      expect(iss, contains('.fushi-setup-write-test'));
      expect(iss, contains('function NextButtonClick'));
      expect(iss, contains('CurPageID = wpSelectDir'));
      expect(iss, contains('InstallDirWritable(WizardDirValue)'));
    });
  });

  group('自定义数据位置页与 data_root.bootstrap 已移除', () {
    test('fushi.iss 不再创建数据位置页或写引导文件', () {
      for (final String forbidden in <String>[
        'CreateInputDirPage',
        'DataRootPage',
        'data_root.bootstrap',
        'WriteDataRootBootstrap',
        'IsFreshInstall',
        'FushiUninstallKey',
      ]) {
        expect(
          iss.contains(forbidden),
          isFalse,
          reason: 'fushi.iss 不得再出现 $forbidden',
        );
      }
    });

    test('MD3 布局不再引用数据位置页', () {
      expect(md3Layout.contains('DataRootPage'), isFalse);
      expect(md3Layout.contains('Md3LayoutDataRootPage'), isFalse);
    });

    test('Dart 侧 bootstrap 文件及其测试已删除', () {
      expect(
        File('lib/src/storage/installer_data_root_bootstrap.dart').existsSync(),
        isFalse,
        reason: 'data_root.bootstrap 的消费者必须删除',
      );
      expect(
        File(
          'test/storage/installer_data_root_bootstrap_test.dart',
        ).existsSync(),
        isFalse,
        reason: '消费者删除后旧契约测试不应留下',
      );
    });
  });

  group('原地覆盖升级保留 userdata', () {
    test('AppId 不变（Inno 原地升级的前提）', () {
      expect(
        iss,
        contains('AppId={{8F2C1A3E-7B4D-4E9A-9C21-0A1B2C3D4E5F}}'),
        reason: '改 AppId 会让升级变成并存安装，userdata 不再跟着程序走',
      );
    });

    test('[Files] 不把 userdata 打进安装载荷', () {
      final String files = section('Files');
      final List<String> sourceLines = files
          .split(RegExp(r'\r?\n'))
          .where((String line) => line.trimLeft().startsWith('Source:'))
          .toList();
      expect(sourceLines, isNotEmpty, reason: '没有 Source 行，守卫等于空转');
      for (final String line in sourceLines) {
        final String? sourceValue = RegExp(
          r'^Source:\s*"([^"]*)"',
        ).firstMatch(line)?.group(1);
        expect(sourceValue, isNotNull, reason: 'Source 行无法解析: $line');
        expect(
          sourceValue!.toLowerCase(),
          isNot(contains('userdata')),
          reason: '安装载荷不得来自 userdata: $line',
        );
        expect(
          RegExp(
            r'DestDir:\s*"[^"]*userdata',
            caseSensitive: false,
          ).hasMatch(line),
          isFalse,
          reason: '安装载荷不得写入 userdata: $line',
        );
      }
      final String recursiveLine = sourceLines.firstWhere(
        (String line) => line.contains(r'{#SourceDir}\*'),
        orElse: () => fail('缺少整目录 Source 行'),
      );
      expect(
        RegExp(
          'Excludes:\\s*"[^"]*userdata',
          caseSensitive: false,
        ).hasMatch(recursiveLine),
        isTrue,
        reason: '整目录收包必须排除 userdata，否则运行过 app 的构建目录会把便携状态打进安装包',
      );
    });

    test('[InstallDelete] 不删除 userdata', () {
      expect(
        entries('InstallDelete').toLowerCase(),
        isNot(contains('userdata')),
      );
    });
  });

  group('卸载删除 Program state root，保留 Content root', () {
    test('[UninstallDelete] 覆盖安装目录与回退位置的 userdata', () {
      final String uninstall = entries('UninstallDelete');
      expect(
        RegExp(
          r'Type:\s*filesandordirs;\s*Name:\s*"\{app\}\\userdata"',
          caseSensitive: false,
        ).hasMatch(uninstall),
        isTrue,
        reason: '默认 Program state root 是 {app}\\userdata，卸载必须删除',
      );
      expect(
        RegExp(
          r'Type:\s*filesandordirs;\s*Name:\s*"\{localappdata\}\\MyComic\\userdata"',
          caseSensitive: false,
        ).hasMatch(uninstall),
        isTrue,
        reason: '安装目录不可写时状态回退到 %LOCALAPPDATA%\\MyComic\\userdata，卸载也要删除',
      );
    });

    test('[UninstallDelete] 完全不碰 Content root', () {
      final String uninstall = entries('UninstallDelete').toLowerCase();
      for (final String forbidden in <String>[
        '{userdocs}',
        'documents',
        'downloads',
        'autobackup',
        // Local source root 自 local-source-polish 起叫 `local`。这里必须写
        // **路径限定**的完整形式：裸 `local` 会误匹配上面必须保留的
        // `{localappdata}\MyComic\userdata` 回退项（localappdata 含 "local"）。
        r'{userdocs}\mycomic\local',
      ]) {
        expect(
          uninstall.contains(forbidden),
          isFalse,
          reason: 'Content root 及其子目录不属于卸载范围: $forbidden',
        );
      }
    });
  });
}
