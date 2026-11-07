import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  group('macOS data root security-scoped bookmark guard', () {
    String read(String path) {
      final File file = File(path);
      expect(file.existsSync(), isTrue, reason: 'missing $path');
      return file.readAsStringSync();
    }

    test('entitlements allow app-scoped security bookmarks', () {
      for (final String path in <String>[
        'macos/Runner/DebugProfile.entitlements',
        'macos/Runner/Release.entitlements',
      ]) {
        final String src = read(path);
        expect(
            src, contains('com.apple.security.files.user-selected.read-write'));
        expect(src, contains('com.apple.security.files.bookmarks.app-scope'));
      }
    });

    test('AppDelegate creates and restores security-scoped bookmarks', () {
      final String src = read('macos/Runner/AppDelegate.swift');
      expect(src, contains('app.fushi/data_root_access'));
      expect(src, contains('bookmarkData('));
      expect(src, contains('.withSecurityScope'));
      expect(src, contains('startAccessingSecurityScopedResource()'));
      expect(src, contains('activeSecurityScopedURLs'));
    });

    test('registers custom channels on the nested Flutter controller', () {
      final String appDelegate =
          maskComments(read('macos/Runner/AppDelegate.swift'));
      final String mainWindow =
          maskComments(read('macos/Runner/MainFlutterWindow.swift'));

      expect(
        mainWindow,
        contains('self.contentViewController = macOSWindowUtilsViewController'),
        reason: 'the macOS window wraps Flutter in macos_window_utils',
      );
      final int wrapperIdx =
          appDelegate.indexOf('as? MacOSWindowUtilsViewController');
      final int nestedControllerIdx = appDelegate.indexOf(
        'windowController.flutterViewController',
        wrapperIdx,
      );
      final int dataRootChannelIdx =
          appDelegate.indexOf('app.fushi/data_root_access');
      final int dataRootMessengerIdx = appDelegate.indexOf(
        'binaryMessenger: controller.engine.binaryMessenger',
        dataRootChannelIdx,
      );
      final int dataRootHandlerIdx = appDelegate.indexOf(
        'channel.setMethodCallHandler',
        dataRootMessengerIdx,
      );
      final int dataRootDelegateIdx = appDelegate.indexOf(
        'self?.handleDataRootAccess(call, result: result)',
        dataRootHandlerIdx,
      );
      final int foregroundChannelIdx =
          appDelegate.indexOf('app.fushi.reader/foreground_selection');
      final int foregroundMessengerIdx = appDelegate.indexOf(
        'binaryMessenger: controller.engine.binaryMessenger',
        foregroundChannelIdx,
      );
      final int foregroundHandlerIdx = appDelegate.indexOf(
        'foregroundSelectionChannel.setMethodCallHandler',
        foregroundMessengerIdx,
      );
      final int foregroundDelegateIdx = appDelegate.indexOf(
        'AppDelegate.handleForegroundSelection(call, result: result)',
        foregroundHandlerIdx,
      );
      expect(wrapperIdx, greaterThan(0));
      expect(nestedControllerIdx, greaterThan(wrapperIdx));
      expect(dataRootChannelIdx, greaterThan(nestedControllerIdx));
      expect(dataRootMessengerIdx, greaterThan(dataRootChannelIdx));
      expect(dataRootHandlerIdx, greaterThan(dataRootMessengerIdx));
      expect(dataRootDelegateIdx, greaterThan(dataRootHandlerIdx));
      expect(foregroundChannelIdx, greaterThan(dataRootDelegateIdx));
      expect(foregroundMessengerIdx, greaterThan(foregroundChannelIdx));
      expect(foregroundHandlerIdx, greaterThan(foregroundMessengerIdx));
      expect(foregroundDelegateIdx, greaterThan(foregroundHandlerIdx));
      expect(
        appDelegate,
        isNot(contains('contentViewController as? FlutterViewController')),
        reason: 'the top-level controller is MacOSWindowUtilsViewController; '
            'casting it directly silently skips channel registration',
      );
    });

    // Ticket 01：旧 data_root 已退出根解析，macOS 安全域书签恢复只保留在旧迁移
    // helper 里（票 12 删除）。Content root 切换所需的书签接线由票 08 负责。

    test('migration stores bookmark before data_root path', () {
      final String src =
          read('lib/src/sync/sync_settings_schema/data_root.part.dart');
      final int createIdx = src.indexOf('createBookmarkForPath(picked)');
      final int migrateIdx = src.indexOf('DataRootMigrator().migrate(');
      final int storeIdx = src.indexOf('MacOSDataRootAccess.storeBookmark');
      final int pathIdx = src.indexOf('setString(AppPaths.dataRootPrefKey');
      expect(createIdx, greaterThan(0));
      expect(migrateIdx, greaterThan(0));
      expect(createIdx, lessThan(migrateIdx),
          reason:
              'bookmark creation must happen while NSOpenPanel access is live');
      expect(storeIdx, greaterThan(0));
      expect(pathIdx, greaterThan(0));
      expect(storeIdx, lessThan(pathIdx),
          reason: 'new process must not see data_root without its bookmark');
    });

    test('migration restores the previous bookmark when data_root write fails',
        () {
      final String src =
          read('lib/src/sync/sync_settings_schema/data_root.part.dart');
      final int previousIdx = src.indexOf('previousBookmark');
      final int storeIdx = src.indexOf('MacOSDataRootAccess.storeBookmark');
      final int rootWriteIdx =
          src.indexOf('setString(AppPaths.dataRootPrefKey');
      final int restoreIdx = src.indexOf('MacOSDataRootAccess.restoreBookmark');
      expect(previousIdx, greaterThan(0));
      expect(storeIdx, greaterThan(0));
      expect(rootWriteIdx, greaterThan(0));
      expect(restoreIdx, greaterThan(rootWriteIdx),
          reason:
              'if data_root write fails after bookmark write, the old bookmark must be restored');
      expect(previousIdx, lessThan(storeIdx),
          reason: 'old bookmark has to be captured before it is overwritten');
    });
  });
}
