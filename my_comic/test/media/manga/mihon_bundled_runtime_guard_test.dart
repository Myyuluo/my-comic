import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the local Windows build contract for the Bundled extension runtime.
///
/// `flutter build windows` does not produce `mihon_bridge`; the build-and-run
/// script is the only thing that keeps it in the Release bundle. These checks
/// are intentionally source-level: the failure mode is a packaging omission
/// that no unit test can observe from inside the app.
void main() {
  String read(String relativeToMyComic) {
    final File file = File(relativeToMyComic);
    expect(file.existsSync(), isTrue,
        reason: 'expected file at ${file.absolute.path}');
    return file.readAsStringSync();
  }

  test('Windows build-and-run script bundles the official extension runtime',
      () {
    final String script = read('../script/build_and_run.ps1');

    expect(script, contains(r'.dart_tool'),
        reason: 'the runtime cache must live inside the repo and stay ignored');
    expect(script, contains(r"$BundleDir = Join-Path $ReleaseDir 'mihon_bridge'"),
        reason: 'the runtime must be copied next to the Release executable');
    expect(script,
        contains(r'Copy-Item -LiteralPath $CacheDir -Destination $staging -Recurse -Force'),
        reason: 'the cache must be staged before replacing the bundle');
    expect(script, contains('checksums.json'),
        reason: 'the copied runtime must be checked against its manifest');
    expect(script,
        contains('648886cac618a0119c9108573ba0d7bf09db420926e3044d76ec16ec7777e4df'),
        reason: 'the official Fushi v3.0.0 runtime hash must be pinned');
    expect(script, contains('Get-FileHash'),
        reason: 'the runtime jar must be hash-verified after copying');
    expect(script, contains('build_desktop_runtime.ps1'),
        reason: 'the cache-miss fallback must reuse the upstream build step');
    expect(script, contains('MYCOMIC_MIHON_RUNTIME_SOURCE'),
        reason: 'seeding from an existing runtime must be explicit, not '
            'hardcoded to a machine-specific path');
    expect(script, contains(r'Start-Process -FilePath $Exe'),
        reason: 'the script must launch the built executable');
    expect(script, isNot(contains('Get-Command java')));
    expect(script, isNot(contains('where.exe java')));
    expect(script, isNot(contains('JAVA_HOME')),
        reason: 'the app ships its own runtime; system Java is never a source');
  });

  test('root launcher invokes the Windows build-and-run script', () {
    final String launcher = read('../启动MyComic.bat');

    expect(launcher, contains('build_and_run.ps1'));
    expect(launcher, contains('MyComic.exe'));
  });

  test('the runtime adapter only launches the copy next to the executable', () {
    final String runtime =
        read('lib/src/media/manga/mihon/desktop_mihon_runtime.dart');

    expect(runtime, contains('Platform.resolvedExecutable'));
    expect(runtime, contains("'mihon_bridge'"));
    expect(runtime, isNot(contains('MYCOMIC_MIHON_RUNTIME_SOURCE')),
        reason: 'runtime discovery is a build-time concern, not a runtime '
            'fallback; the app must stay fail-closed');
    expect(runtime, isNot(contains('JAVA_HOME')));
  });
}
