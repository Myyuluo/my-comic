import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Ticket 12 契约守卫：旧的 documents/support/temp root、旧 data-root 布局锚点、
/// 整目录迁移器与死掉的非漫画存储 getter 不得回归。
///
/// 这不是行为测试——它是**源码契约**：storage-layout 的调用方全部迁移到
/// Content root / Program state root 之后，任何把旧入口加回来的改动都应立刻变红。
void main() {
  group('AppPaths 只保留新 root API', () {
    late String source;

    setUpAll(() {
      source = File('lib/src/storage/app_paths.dart').readAsStringSync();
    });

    test('暴露 Content root / Program state root 及其全部派生根', () {
      for (final String required in <String>[
        'contentRoot',
        'downloadsRoot',
        'autobackupRoot',
        'localComicRoot',
        'programStateRoot',
        'stateRoot',
        'cacheRoot',
        'customFontsRoot',
        'webView2Root',
        'logsRoot',
        'contentRootDirectory()',
        'downloadsRootDirectory()',
        'autobackupRootDirectory()',
        'localComicRootDirectory()',
        'programStateRootDirectory()',
        'stateRootDirectory()',
        'cacheRootDirectory()',
        'customFontsRootDirectory()',
        'webView2RootDirectory()',
        'logsRootDirectory()',
      ]) {
        expect(
          source.contains(required),
          isTrue,
          reason: 'AppPaths 必须保留新 root API：$required',
        );
      }
    });

    test('不再有旧 root getter / alias / 布局锚点 / 迁移 helper', () {
      for (final String forbidden in <String>[
        'documentsRoot',
        'supportRoot',
        'tempRoot',
        'documentsRootDirectory',
        'supportRootDirectory',
        'tempRootDirectory',
        'documentsSubdirectory',
        'audiobooksDirectory',
        'epubBooksDirectory',
        'videoCoversDirectory',
        'gameCoversDirectory',
        'videoSubtitlesDirectory',
        'mpvShadersDirectory',
        'mpvLuaScriptsDirectory',
        'remoteVideosDirectory',
        'srsBackupsDirectory',
        'dataRootPrefKey',
        'dataRootDocumentsChild',
        'dataRootSupportChild',
        'documentsLayoutPrefKey',
        'documentsLayoutFlat',
        'documentsLayoutNested',
        'documentsContainerPrefKey',
        'defaultDocumentsChildSegments',
        'defaultLocationDocumentsRoot',
        'documentsRootIsFushiOwned',
        'ensureDocumentsContainerDecided',
        'existingInstallHasDatabase',
        'rootsForDataRoot',
        'fushiOwnedDocumentsEntries',
        'isSafeNestedTargetInSharedDocuments',
        'debugDataRootReader',
        'debugResetDocumentsLayoutCache',
        'debugSetDocumentsContainer',
      ]) {
        expect(
          source.contains(forbidden),
          isFalse,
          reason: 'AppPaths 不得再出现旧入口：$forbidden',
        );
      }
    });

    test('不再写入旧 data-root 偏好键', () {
      for (final String literal in <String>[
        "'data_root'",
        "'documents_layout'",
        "'documents_container'",
        "'data_root.bootstrap'",
      ]) {
        expect(source.contains(literal), isFalse, reason: '旧偏好键不得回归：$literal');
      }
    });
  });

  test('旧迁移器 / 遮罩 / 布局辅助文件已删除', () {
    for (final String path in <String>[
      'lib/src/storage/data_root_migrator.dart',
      'lib/src/storage/data_root_migration_view.dart',
      'lib/src/storage/macos_data_root_access.dart',
      'lib/src/storage/sandbox_relocation.dart',
      'lib/src/storage/legacy_support_dir_migration.dart',
      'lib/src/sync/sync_settings_schema/data_root.part.dart',
      'lib/src/media/manga/library/manga_chapter_storage.dart',
    ]) {
      expect(
        File(path).existsSync(),
        isFalse,
        reason: '旧存储实现已由 ticket 12 删除，不得回归：$path',
      );
    }
  });

  test('旧哈希章节目录 helper 不再提供路径/判据 API', () {
    final String engineChapterStorage = File(
      '../packages/fushi_engine/lib/media/manga/manga_chapter_storage.dart',
    ).readAsStringSync();
    for (final String forbidden in <String>[
      'mangaChapterDirectory(',
      'mangaChapterJsonFile(',
      'mangaChapterImagesDirectory(',
      'readDownloadedChapterPayload',
      'hasAnyChapterDirSync',
      'kMangaChaptersDirName',
    ]) {
      expect(
        engineChapterStorage.contains(forbidden),
        isFalse,
        reason: '旧哈希布局 helper 已删除，不得回归：$forbidden',
      );
    }
    // 互联协议仍需要的 digest 形状必须保留。
    expect(engineChapterStorage, contains('mangaChapterDigest'));
    expect(engineChapterStorage, contains('isMangaChapterDigest'));
  });

  test('EnginePaths 不再暴露死掉的非漫画存储 getter', () {
    final String enginePaths = File(
      '../packages/fushi_engine/lib/foundation/engine_paths.dart',
    ).readAsStringSync();
    for (final String forbidden in <String>[
      'documentsSubdirectory',
      'videoCoversDirectory',
      'videoSubtitlesDirectory',
      'epubBooksDirectory',
      'audiobooksDirectory',
    ]) {
      expect(
        enginePaths.contains(forbidden),
        isFalse,
        reason: '死掉的非漫画存储 getter 已删除，不得回归：$forbidden',
      );
    }
  });

  test('lib/ 下没有任何旧 root API 调用', () {
    final RegExp oldApi = RegExp(
      r'\bAppPaths\.(documentsRootDirectory|supportRootDirectory|'
      r'tempRootDirectory|documentsRoot|supportRoot|tempRoot|'
      r'documentsSubdirectory|audiobooksDirectory|epubBooksDirectory|'
      r'videoCoversDirectory|gameCoversDirectory|videoSubtitlesDirectory|'
      r'mpvShadersDirectory|mpvLuaScriptsDirectory|remoteVideosDirectory|'
      r'srsBackupsDirectory|dataRootPrefKey|dataRootDocumentsChild|'
      r'dataRootSupportChild|documentsLayoutPrefKey|documentsLayoutFlat|'
      r'documentsLayoutNested|documentsContainerPrefKey|'
      r'defaultDocumentsChildSegments|defaultLocationDocumentsRoot|'
      r'documentsRootIsFushiOwned|ensureDocumentsContainerDecided|'
      r'existingInstallHasDatabase|rootsForDataRoot|'
      r'fushiOwnedDocumentsEntries|isSafeNestedTargetInSharedDocuments|'
      r'debugDataRootReader|debugResetDocumentsLayoutCache|'
      r'debugSetDocumentsContainer)\b',
    );
    final List<String> hits = <String>[];
    int scanned = 0;
    for (final FileSystemEntity entity in Directory(
      'lib',
    ).listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      scanned++;
      final String src = entity.readAsStringSync();
      for (final RegExpMatch match in oldApi.allMatches(src)) {
        hits.add('${entity.path}: ${match.group(0)}');
      }
    }
    expect(scanned, greaterThan(500), reason: '源码扫描规模异常，守卫可能失效');
    expect(hits, isEmpty, reason: '这些调用点必须改用新 root API：\n${hits.join('\n')}');
  });

  test('lib/ 不再经 enginePaths 的旧 documents/support/temp getter 取根', () {
    final RegExp engineOld = RegExp(
      r'\benginePaths\.(documentsRootDirectory|supportRootDirectory|'
      r'tempRootDirectory)\b',
    );
    final List<String> hits = <String>[];
    for (final FileSystemEntity entity in Directory(
      'lib',
    ).listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String src = entity.readAsStringSync();
      for (final RegExpMatch match in engineOld.allMatches(src)) {
        hits.add('${entity.path}: ${match.group(0)}');
      }
    }
    expect(
      hits,
      isEmpty,
      reason:
          'App 代码必须直接经 AppPaths 的新 root API；引擎桥只留给引擎包：\n'
          '${hits.join('\n')}',
    );
  });

  test('章节载体解析只经数据库映射，不再按标题推导或回退旧哈希布局', () {
    final String indexSource = File(
      'lib/src/media/manga/download/download_library_index.dart',
    ).readAsStringSync();
    expect(
      indexSource,
      contains('getMangaChapterDir('),
      reason: '章节目录必须从 manga_chapter_dirs 映射解析',
    );
    expect(
      indexSource,
      isNot(contains('downloadChapterFolderName(')),
      reason: '解析路径不得按标题/名称重新拼目录名',
    );
    expect(
      indexSource,
      isNot(contains('mangaChapterDirectory(')),
      reason: '旧哈希布局回退必须删除',
    );
    expect(indexSource, isNot(contains('legacyLayout')), reason: '旧哈希布局分支必须删除');

    final String readerSource = File(
      'lib/src/media/manga/reader/manga_fushi_page.dart',
    ).readAsStringSync();
    expect(
      readerSource,
      isNot(contains('raw: chapter.name')),
      reason: '阅读器不得用章节标题推导章目录',
    );
  });

  test('互联 host 的章节供给走 Download library 映射，不读旧哈希布局', () {
    final String host = File(
      '../packages/fushi_engine/lib/sync/local_library_host_service/manga.part.dart',
    ).readAsStringSync();
    expect(host, contains('getMangaChapterDir('));
    expect(host, contains('downloadChapterDirectory('));
    expect(host, contains('readDownloadLibraryChapterPayload('));
    expect(
      host,
      isNot(contains('mangaChapterDirectoryByDigest(')),
      reason: '旧哈希章目录定位必须删除',
    );
    expect(
      host,
      isNot(contains('readDownloadedChapterPayload(')),
      reason: '旧布局页表读取必须删除',
    );
    final String books = File(
      '../packages/fushi_engine/lib/sync/local_library_host_service/books.part.dart',
    ).readAsStringSync();
    expect(books, contains('getMangaChapterDirNamesForBook'));
    expect(books, isNot(contains('hasAnyChapterDirSync')));
  });

  test('fresh start：main() 不搬、不读旧 app-support / prefs 域', () {
    final String mainSource = File('lib/main.dart').readAsStringSync();
    expect(
      mainSource.contains('migrateLegacySupportDir'),
      isFalse,
      reason: '旧 Fushi/Hibiki app-support 数据一律忽略，启动不得再搬旧根',
    );
    expect(
      mainSource.contains('recoverLegacyMacosPrefs'),
      isFalse,
      reason: '旧 NSUserDefaults 域里的数据根锚点同样不得再被捞回',
    );
  });

  test('核心消费点经 AppPaths 的新根派生，不直连旧 support/documents', () {
    final String appModel = File(
      'lib/src/models/app_model.dart',
    ).readAsStringSync();
    expect(appModel, contains('_appPaths.contentRoot'));
    expect(appModel, contains('_appPaths.stateRoot'));
    expect(appModel, contains('_appPaths.cacheRoot'));

    final String bridge = File(
      'lib/src/engine_bindings.dart',
    ).readAsStringSync();
    expect(bridge, contains('AppPaths.contentRootDirectory'));
    expect(bridge, contains('AppPaths.stateRootDirectory'));
    expect(bridge, contains('AppPaths.cacheRootDirectory'));
  });
}
