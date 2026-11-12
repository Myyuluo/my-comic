import 'dart:io';

import 'package:my_comic_cli/my_comic_cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await runMyComicCli(args);
}
