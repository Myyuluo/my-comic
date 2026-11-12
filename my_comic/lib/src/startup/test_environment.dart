import 'dart:io';

import 'package:path/path.dart' as p;

const String _dartDefineTestRoot = String.fromEnvironment('MYCOMIC_TEST_ROOT');
const String _dartDefineTestRunId =
    String.fromEnvironment('MYCOMIC_TEST_RUN_ID');

String? myComicTestRootPath({
  Map<String, String>? environment,
  String dartDefineRoot = _dartDefineTestRoot,
}) {
  final String raw = dartDefineRoot.trim().isNotEmpty
      ? dartDefineRoot
      : (environment ?? Platform.environment)['MYCOMIC_TEST_ROOT'] ?? '';
  if (raw.trim().isEmpty) {
    return null;
  }
  return Directory(raw).absolute.path;
}

String? myComicTestRunId({
  Map<String, String>? environment,
  String dartDefineRunId = _dartDefineTestRunId,
}) {
  final String raw = dartDefineRunId.trim().isNotEmpty
      ? dartDefineRunId
      : (environment ?? Platform.environment)['MYCOMIC_TEST_RUN_ID'] ?? '';
  return raw.trim().isEmpty ? null : raw.trim();
}

Directory? myComicTestDirectory(
  String child, {
  Map<String, String>? environment,
  String dartDefineRoot = _dartDefineTestRoot,
}) {
  final String? root = myComicTestRootPath(
    environment: environment,
    dartDefineRoot: dartDefineRoot,
  );
  if (root == null) {
    return null;
  }
  final Directory directory = Directory(p.join(root, child));
  if (!directory.existsSync()) {
    directory.createSync(recursive: true);
  }
  return directory;
}
