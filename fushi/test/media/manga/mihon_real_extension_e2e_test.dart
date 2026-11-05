import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/desktop_mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi_core/fushi_core.dart';

/// Real-extension acceptance harness for ticket 17.
///
/// Drives the real [DesktopMihonRuntime] adapter against the official Fushi
/// v3.0.0 `mihon_bridge` extracted from the installer and the real Keiyoushi
/// Atsumaru extension APK.
///
/// The runtime-backed tests only run when `FUSHI_TEST_MIHON_RESOURCES` points
/// at a complete runtime directory and `FUSHI_TEST_MIHON_APK` points at the
/// downloaded extension APK. The store-index test additionally requires
/// `FUSHI_TEST_MIHON_STORE_E2E=1` because it accesses the network.
void main() {
  final String resources = Platform.environment['FUSHI_TEST_MIHON_RESOURCES'] ?? '';
  final String apkPath = Platform.environment['FUSHI_TEST_MIHON_APK'] ?? '';
  final bool available = Platform.isWindows &&
      resources.isNotEmpty &&
      apkPath.isNotEmpty &&
      File('$resources/runtime/bin/java.exe').existsSync() &&
      File('$resources/m-extension-server.jar').existsSync() &&
      File(apkPath).existsSync();
  final bool storeAvailable = Platform.isWindows &&
      Platform.environment['FUSHI_TEST_MIHON_STORE_E2E'] == '1';

  test('real extension: inspect, browse, search, details, chapters, pages, image', () async {
    final Directory data = await Directory.systemTemp.createTemp('mihon-e2e-');
    final DesktopMihonRuntime runtime = DesktopMihonRuntime(
      dataDirectory: data,
      resourceDirectory: Directory(resources),
    );
    try {
      final MihonCapabilities capabilities = await runtime.getCapabilities();
      expect(capabilities.isUsable, isTrue);
      final int? pid = runtime.processId;
      expect(pid, isNotNull);
      // ignore: avoid_print
      print('sidecar pid=$pid bridgeVersion=${capabilities.bridgeVersion} '
          'sourceFactory=${capabilities.sourceFactory} '
          'preferenceCallbacks=${capabilities.preferenceCallbacks} '
          'imageProxy=${capabilities.imageProxy} '
          'sourceUrls=${capabilities.sourceUrls}');

      final MihonExtensionInspection inspection =
          await runtime.inspectExtension(apkPath);
      // ignore: avoid_print
      print('inspection: ${inspection.name} ${inspection.packageName} '
          'v${inspection.versionName} code=${inspection.apkVersionCode} '
          'lib=${inspection.libVersion} signer=${inspection.signerSha256}');
      expect(inspection.packageName,
          'eu.kanade.tachiyomi.extension.en.atsumaru');
      expect(inspection.libVersion, '1.6');
      expect(inspection.signerSha256,
          '9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2');

      final MihonExtensionRef extension = MihonExtensionRef(
        packageName: inspection.packageName,
        apkPath: apkPath,
      );
      final List<MihonSource> sources =
          await runtime.listSources(extension);
      expect(sources, isNotEmpty);
      final MihonSource source = sources.first;
      // ignore: avoid_print
      print('sources: ${sources.map((MihonSource s) => '${s.id}/${s.name}/${s.language}/${s.baseUrl}').join(', ')}');

      final MihonMangaPage popular =
          await runtime.getPopular(extension, source, page: 1);
      expect(popular.items, isNotEmpty);
      // ignore: avoid_print
      print('popular=${popular.items.length} first=${popular.items.first.title}');

      final MihonMangaPage search =
          await runtime.search(extension, source, page: 1, query: 'Frieren');
      expect(search.items, isNotEmpty);
      // ignore: avoid_print
      print('search=${search.items.length} first=${search.items.first.title}');

      final MihonManga details = await runtime.getDetails(
        extension,
        source,
        search.items.first,
      );
      expect(details.title, isNotEmpty);
      // ignore: avoid_print
      print('details=${details.title} author=${details.author} '
          'cover=${details.coverUrl}');

      final List<MihonChapter> chapters =
          await runtime.getChapters(extension, source, details);
      expect(chapters, isNotEmpty);
      // ignore: avoid_print
      print('chapters=${chapters.length} first=${chapters.first.name}');

      List<MihonPage> pages = const <MihonPage>[];
      MihonChapter? selected;
      for (final MihonChapter chapter in chapters.take(8)) {
        try {
          pages = await runtime.getPages(extension, source, chapter);
          if (pages.isNotEmpty) {
            selected = chapter;
            break;
          }
        } on Object catch (error) {
          // ignore: avoid_print
          print('skip chapter ${chapter.name}: $error');
        }
      }
      expect(pages, isNotEmpty);
      // ignore: avoid_print
      print('chapter=${selected?.name} pages=${pages.length} '
          'first=${pages.first.resolvedUrl}');

      final Uint8List image =
          await runtime.fetchImage(extension, source, pages.first);
      expect(image, isNotEmpty);
      // ignore: avoid_print
      print('page image bytes=${image.length}');

      final String coverUrl = details.coverUrl ?? '';
      if (coverUrl.isNotEmpty) {
        final Uint8List cover =
            await runtime.fetchSourceImage(extension, source, coverUrl);
        expect(cover, isNotEmpty);
        // ignore: avoid_print
        print('cover image bytes=${cover.length}');
      }

      expect(runtime.processId, pid);
    } finally {
      await runtime.dispose();
      expect(runtime.processId, isNull);
      await data.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)), skip: !available);

  test('real extension install through MihonManager writes DB and trusts signer', () async {
    final Directory root =
        await Directory.systemTemp.createTemp('mihon-install-');
    // AppModel 启动时提前建好 tmp/ 与 extensions/，单测直接复用 manager
    // 需要自己建。
    await Directory('${root.path}/tmp').create(recursive: true);
    await Directory('${root.path}/extensions').create(recursive: true);
    final Directory data =
        await Directory.systemTemp.createTemp('mihon-install-data-');
    final FushiDatabase database = FushiDatabase.forTesting(NativeDatabase.memory());
    final DesktopMihonRuntime runtime = DesktopMihonRuntime(
      dataDirectory: data,
      resourceDirectory: Directory(resources),
    );
    final MihonManager manager = MihonManager(
      database: database,
      rootDirectory: root,
      runtime: runtime,
      ownsRuntime: false,
      fetchDownloadCounts: false,
    );
    try {
      await manager.reload();
      final MihonInstallProposal proposal =
          await manager.prepareLocalInstall(apkPath);
      expect(proposal.inspection.packageName,
          'eu.kanade.tachiyomi.extension.en.atsumaru');
      expect(proposal.signerTrusted, isFalse);
      // ignore: avoid_print
      print('proposal: ${proposal.inspection.name} trusted=${proposal.signerTrusted} '
          'sha=${proposal.apkSha256} signer=${proposal.inspection.signerSha256}');
      await manager.commitInstall(proposal, trustSigner: true);

      final MangaExtensionRow? installed = await database
          .getMangaExtension('eu.kanade.tachiyomi.extension.en.atsumaru');
      expect(installed, isNotNull);
      expect(
        installed!.signerSha256,
        '9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2',
      );
      expect(
        await database.isMangaSignerTrusted(installed.signerSha256),
        isTrue,
      );
      final List<MangaOnlineSourceRow> sources =
          await database.getMangaOnlineSources(mediaKind: 'manga');
      final List<MangaOnlineSourceRow> mine = sources
          .where((MangaOnlineSourceRow source) =>
              source.extensionPackage == installed.packageName)
          .toList();
      expect(mine, hasLength(1));
      expect(mine.single.name, 'Atsumaru');
      final File target = File(
        '${root.path}/extensions/${installed.packageName}.apk',
      );
      expect(target.existsSync(), isTrue);
      // ignore: avoid_print
      print('installed: ${installed.name} v${installed.versionName} '
          'lib=${installed.libVersion} sources=${mine.length} '
          'apk=${target.path} (${target.lengthSync()} bytes) trusted=true');
    } finally {
      manager.dispose();
      await database.close();
      await runtime.dispose();
      if (await root.exists()) await root.delete(recursive: true);
      if (await data.exists()) await data.delete(recursive: true);
    }
  }, skip: !available);

  test('real Keiyoushi index.pb: fetch, parse, resolve extension list', () async {
    final MihonExtensionStoreClient client = MihonExtensionStoreClient();
    try {
      final MihonStoreFetchResult result = await client.fetchStore(
        'https://github.com/keiyoushi/extensions/raw/repo/index.pb',
      );
      final MihonStore? store = result.store;
      expect(store, isNotNull);
      // ignore: avoid_print
      print('store=${store!.name} badge=${store.badgeLabel} '
          'signingKey=${store.signingKey} format=${store.format}');
      expect(store.name, 'Keiyoushi');
      expect(
        store.signingKey,
        '9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2',
      );
      final List<MihonAvailableExtension> extensions =
          await client.fetchExtensions(store);
      expect(extensions.length, greaterThan(1000));
      final MihonAvailableExtension atsumaru = extensions.firstWhere(
        (MihonAvailableExtension extension) =>
            extension.packageName ==
            'eu.kanade.tachiyomi.extension.en.atsumaru',
      );
      // ignore: avoid_print
      print('extensions=${extensions.length} atsumaru='
          '${atsumaru.name} v${atsumaru.versionName} '
          'code=${atsumaru.extensionVersionCode} lib=${atsumaru.libVersion} '
          'apk=${atsumaru.apkUrl}');
      expect(atsumaru.extensionVersionCode, 106026);
      expect(atsumaru.versionName, '1.6.26');
      expect(atsumaru.libVersion, '1.6');
    } finally {
      client.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)), skip: !storeAvailable);
}
