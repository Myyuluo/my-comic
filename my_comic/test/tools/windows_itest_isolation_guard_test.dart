import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Load only function definitions through the AST: never execute the runner's
// main body or enumerate/modify real processes in this fixture.
const String _ownershipFixture = r'''
$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
  (Join-Path (Get-Location) 'tool/run_windows_itest.ps1'),
  [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
foreach ($functionName in @('Test-RunnerProcessAncestry',
    'Get-MyComicProcessSnapshot', 'Add-RunnerSnapshot', 'Get-RunnerWindowHandle')) {
  $definition = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq $functionName
  }, $true)
  if ($null -eq $definition) { throw "Missing function $functionName" }
  Invoke-Expression $definition.Extent.Text
}
$debugPath = 'D:\fixture\build\windows\x64\runner\Debug\MyComic.exe'
$fixtures = @(
  @{ id=10; path='D:\fixture\build\windows\x64\runner\Release\MyComic.exe'; parent=200 },
  @{ id=11; path=$debugPath; parent=200 },
  @{ id=12; path=$debugPath.ToUpperInvariant(); parent=210 },
  @{ id=13; path=$debugPath; parent=999 },
  @{ id=14; path=($debugPath + '.other'); parent=200 },
  @{ id=15; path='D:\installed\MyComic.exe'; parent=200 },
  @{ id=16; path=$debugPath; parent=200 },
  @{ id=17; path=''; parent=200 },
  @{ id=18; path=$debugPath; parent=404 }
)
function Get-Process {
  param($Name, $ErrorAction)
  foreach ($entry in $fixtures) {
    [pscustomobject]@{ Id=$entry.id; MainWindowTitle='fixture'; MainWindowHandle=($entry.id+100) }
  }
}
function Get-CimInstance {
  param($ClassName, $Filter, $ErrorAction)
  if ($Filter -eq "Name = 'MyComic.exe'") {
    foreach ($entry in $fixtures) {
      [pscustomobject]@{ ProcessId=$entry.id; ExecutablePath=$entry.path;
        ParentProcessId=$entry.parent; CommandLine='fixture'; CreationDate='fixture' }
    }
  } elseif ($Filter -eq 'ProcessId = 210') {
    [pscustomobject]@{ ParentProcessId=200 }
  } elseif ($Filter -eq 'ProcessId = 999') {
    [pscustomobject]@{ ParentProcessId=998 }
  } elseif ($Filter -eq 'ProcessId = 998') {
    [pscustomobject]@{ ParentProcessId=999 }
  } elseif ($Filter -ne 'ProcessId = 404') {
    throw "Unexpected process lookup: $Filter"
  }
}
$before = @(Get-MyComicProcessSnapshot -CurrentRunId 'fixture' -ExpectedRunnerPath $debugPath)
if (@($before | Where-Object { $_.isTestRunner }).Count -ne 0) {
  throw 'A pre-existing process was classified as this test runner'
}
if (@($before | Where-Object { $_.isExpectedRunnerPath }).Count -ne 5) {
  throw 'Exact Debug conflict detection included Release or missed Debug'
}
$snapshot = @(Get-MyComicProcessSnapshot -CurrentRunId 'fixture' `
  -ExpectedRunnerPath $debugPath -BeforeProcessIds @(11) -LauncherProcessId 200)
$ownedIds = @($snapshot | Where-Object { $_.isTestRunner } | ForEach-Object { $_.pid })
if (($ownedIds -join ',') -ne '12,16') { throw "Unexpected owned processes: $ownedIds" }
$handle = Get-RunnerWindowHandle -Snapshot $snapshot
if ($handle.ToInt64() -ne 112) { throw 'Window capture selected an unowned process' }
$records = [System.Collections.ArrayList]::new()
Add-RunnerSnapshot -RunnerRecords $records -Snapshot $snapshot
if (($records.pid -join ',') -ne '12,16') { throw 'Recorded an unowned process' }
Write-Output 'PASS ownership fixture: only new exact Debug launcher descendants'
''';

void main() {
  group('Windows integration test isolation contract', () {
    final String script = File('tool/run_windows_itest.ps1').readAsStringSync();

    test('never terminates pre-existing processes', () {
      // BUG-2486: a worktree build output can be a user's manual app session.
      for (final String command in <String>[
        'Stop-Process',
        'taskkill',
        'TerminateProcess',
        '.Kill(',
      ]) {
        expect(
          script,
          isNot(contains(command)),
          reason: 'The runner may report conflicts, never terminate them.',
        );
      }
      expect(script, contains(r'$BlockingRunnerProcesses.Count -gt 0'));
      expect(script, contains('blocked: existing process pid='));
      expect(script, contains(r'$exitCode = 1'));
    });

    test('captures only new exact Debug binaries owned by this launcher', () {
      expect(script, contains(r'build\windows\x64\runner\Debug\MyComic.exe'));
      expect(script, isNot(contains('RunnerPathPrefix')));
      expect(script, contains(r'[string]::Equals($path, $ExpectedRunnerPath,'));
      expect(script, contains('[System.StringComparison]::OrdinalIgnoreCase'));
      expect(script, contains(r'$BeforeProcessIds -notcontains $id'));
      expect(script, contains('Test-RunnerProcessAncestry -ParentProcessId'));
      expect(script, contains(r'$LauncherProcessId = [int]$process.Id'));
      expect(
        script,
        contains(r'$before | Where-Object { $_.isExpectedRunnerPath }'),
      );
      expect(script, contains(r'if (-not $process.isTestRunner) { continue }'));
    });

    test(
      'PowerShell fixture excludes user Release and unrelated Debug processes',
      () {
        final ProcessResult result = Process.runSync('powershell.exe', <String>[
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          _ownershipFixture,
        ]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(result.stdout, contains('PASS ownership fixture'));
      },
      skip: !Platform.isWindows,
    );

    test('records required process and runner evidence files', () {
      for (final String marker in <String>[
        'process-before.json',
        'process-after.json',
        'paths.json',
        'command.log',
        'runner-info.json',
        'exit-code.txt',
      ]) {
        expect(script, contains(marker), reason: 'Missing evidence: $marker');
      }
      expect(script, contains('Get-CimInstance Win32_Process'),
          reason: 'Evidence must include process Path and CommandLine.');
      expect(script, contains('MainWindowTitle'),
          reason: 'Evidence must include window title when available.');
    });

    test('runs with isolated test root, app data, logs, and WebView2 profile',
        () {
      expect(script, contains('MYCOMIC_TEST_ROOT'));
      expect(script, contains('MYCOMIC_TEST_RUN_ID'));
      expect(script, contains('MYCOMIC_WEBVIEW2_USER_DATA_FOLDER'));
      expect(script, contains('--dart-define=MYCOMIC_TEST_ROOT='));
      expect(script, contains('--dart-define=MYCOMIC_TEST_RUN_ID='));
      expect(script, contains('APPDATA'));
      expect(script, contains('LOCALAPPDATA'));
      expect(script, contains('TEMP'));
      expect(script, contains('TMP'));
      expect(script, contains('USERPROFILE'));
    });

    test('app startup honors the isolated test root for app data and logs', () {
      // Ticket 01：Content root / Program state root 的测试隔离经 AppPaths 单一
      // 入口；prefs 隔离落 `<testRoot>/userdata/state/`。
      final String appPaths =
          File('lib/src/storage/app_paths.dart').readAsStringSync();
      final String appModel =
          File('lib/src/models/app_model.dart').readAsStringSync();
      final String errorLog =
          File('lib/src/utils/misc/error_log_service.dart').readAsStringSync();
      final String testPrefs =
          File('lib/src/startup/test_root_shared_preferences.dart')
              .readAsStringSync();

      // 新根的测试隔离判定落在 AppPaths 单一入口。
      expect(appPaths, contains('myComicTestDirectory('));
      expect(appPaths, contains("_testDirectory('content')"));
      expect(appPaths, contains('programStateRootDirName'));
      // prefs 与数据库同住 Program state root 的 state/。
      expect(testPrefs, contains("'userdata'"));
      expect(testPrefs, contains('AppPaths.stateDirName'));
      // 启动期 app_model 经 AppPaths.resolve() 接上隔离根（不绕过单一入口）。
      expect(appModel, contains('AppPaths.resolve('));
      // 日志服务仍独立 honor 隔离的 documents 根。
      expect(errorLog, contains("myComicTestDirectory('app-documents'"));
    });

    test('native logs and WebView2 profile use test-only isolation env vars',
        () {
      final String crashDump =
          File('windows/runner/crash_dump.cpp').readAsStringSync();
      final String wgcLog = File(
        '../packages/flutter_inappwebview_windows/windows/utils/wgc_log.cpp',
      ).readAsStringSync();
      final String inAppWebView = File(
        '../packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp',
      ).readAsStringSync();
      final String webViewEnvironment = File(
        '../packages/flutter_inappwebview_windows/windows/webview_environment/webview_environment.cpp',
      ).readAsStringSync();

      expect(crashDump, contains('MYCOMIC_TEST_ROOT'));
      expect(wgcLog, contains('MYCOMIC_TEST_ROOT'));
      expect(inAppWebView, contains('MYCOMIC_WEBVIEW2_USER_DATA_FOLDER'));
      expect(webViewEnvironment, contains('MYCOMIC_WEBVIEW2_USER_DATA_FOLDER'));
    });
  });
}
