import 'package:flutter/widgets.dart';
import 'package:my_comic/main.dart' as app;
import 'package:my_comic/src/startup/test_root_shared_preferences.dart';
import 'package:my_comic/src/storage/app_paths.dart';
import 'package:my_comic_core/my_comic_core.dart' show MyComicDatabase;

/// Starts the real app after marking the fixture database as an existing,
/// onboarding-complete installation.
///
/// Feature integration tests should not rely on the runtime binding type to
/// suppress first-run UI. They write the same persisted preferences as a user
/// who has completed onboarding. The dedicated clean-install test deliberately
/// calls [app.main] directly so the onboarding path remains covered.
Future<void> launchMyComicTestApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  isolateSharedPreferencesUnderTestRoot();
  final AppPaths paths = await AppPaths.resolve();
  final MyComicDatabase db = MyComicDatabase(paths.stateRoot.path);
  try {
    await db.setPrefTyped<bool>('first_time_setup', false);
    await db.setPrefTyped<bool>('onboarding_completed', true);
  } finally {
    await db.close();
  }
  app.main();
}
