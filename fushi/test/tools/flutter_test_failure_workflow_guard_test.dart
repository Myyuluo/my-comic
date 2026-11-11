import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CI full Flutter tests use the failure-only wrapper and skip goldens',
      () {
    final String mainWorkflow =
        File('../.github/workflows/main.yml').readAsStringSync();

    // The full-suite run is a file-sharded matrix (the shard count lives in
    // the matrix and the --file-shard denominator; see main.yml unit-tests).
    expect(
      mainWorkflow,
      contains('dart run tool/flutter_test_failures.dart '
          r'--file-shard=${{ matrix.shard }}/4 --exclude-tags golden'),
    );
    expect(mainWorkflow, contains('shard: [0, 1, 2, 3]'));
    // Coverage was never uploaded or read by anything and roughly doubled the
    // PR suite. Re-adding it needs a consumer first.
    expect(mainWorkflow, isNot(contains('--coverage')));
    expect(
      mainWorkflow,
      isNot(contains('run: flutter test --coverage --exclude-tags golden')),
    );
    expect(
      mainWorkflow,
      contains('dart ../../fushi/tool/flutter_test_failures.dart'),
    );
  });

  test(
      'the wrapper cannot report a run that executed no tests as green '
      '(BUG-1157)', () {
    final String wrapper =
        File('tool/flutter_test_failures.dart').readAsStringSync();

    // The pass/fail decision must go through the single shared helper, which
    // treats "no done event" and "zero tests" as failures.
    expect(wrapper, contains('resolveFlutterTestVerdictFailure('));
    expect(wrapper, contains('flutterExitCode: exitCode'));

    // A machine-readable verdict line on stdout, so `| tail` pipelines that
    // discard the exit code still show the failure.
    expect(wrapper, contains(r'$kFlutterTestVerdictPrefix FAILED'));
    expect(wrapper, contains(r'$kFlutterTestVerdictPrefix PASSED'));

    // The child's stderr must never be conditionally suppressed: native-assets
    // and compile failures are reported there and nowhere else.
    expect(
      wrapper.split('process.stderr').last,
      isNot(contains('options.verboseOutput')),
    );

    // No unconditional success message that bypasses the verdict.
    expect(wrapper, isNot(contains("stdout.writeln('Flutter tests passed")));
  });
}
