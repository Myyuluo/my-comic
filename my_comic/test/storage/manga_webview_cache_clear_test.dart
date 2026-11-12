import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:my_comic/src/media/manga/cookie/manga_web_view_environment.dart';
import 'package:my_comic/src/storage/manga_cache_clear_service.dart';
import 'package:my_comic/src/storage/manga_webview_cache_clear.dart';

/// Ticket 12：清除缓存里的 WebView / HTTP 缓存步骤。
///
/// 只通过可控 fake 验证：默认与漫画 WebView profile 都通过 CDP
/// `Network.clearBrowserCache` 清 HTTP 缓存；临时 headless WebView 用完即销毁；
/// 某个 profile 失败时继续清其余 profile 并报告部分成功；绝不删除 WebView2
/// 数据目录（cookies / localStorage / IndexedDB / Preferences 保留）。
void main() {
  setUp(() => MangaWebViewEnvironment.debugSetCurrentUserDataFolder(null));
  tearDown(() => MangaWebViewEnvironment.debugSetCurrentUserDataFolder(null));

  test('清理默认与漫画 WebView profile，并销毁临时 headless 会话', () async {
    final _FakeSession defaultSession = _FakeSession('default');
    final _FakeSession mangaSession = _FakeSession('manga');
    final List<String> headlessOpened = <String>[];
    final MangaWebViewCacheClearStep step = MangaWebViewCacheClearStep(
      id: 'webview_http',
      label: 'WebView cache',
      profiles: <MangaWebViewCacheProfile>[
        _profile('default', defaultSession, headlessOpened),
        _profile('manga', mangaSession, headlessOpened),
      ],
    );

    expect(await step.measureBytes(), 0);
    final MangaCacheClearStepResult result = await step.clear();

    expect(result.id, 'webview_http');
    expect(result.freedBytes, 0);
    expect(result.failedEntries, 0);
    expect(headlessOpened, <String>['default', 'manga']);
    expect(defaultSession.clearCalls, 1);
    expect(mangaSession.clearCalls, 1);
    expect(defaultSession.disposed, isTrue);
    expect(mangaSession.disposed, isTrue);
  });

  test('WebView 占用只统计 CDP 会清理的 HTTP cache 子目录', () async {
    final Directory stateRoot = Directory.systemTemp.createTempSync(
      'manga_webview_measure_',
    );
    addTearDown(() {
      if (stateRoot.existsSync()) stateRoot.deleteSync(recursive: true);
    });

    // 默认 profile 的 HTTP cache：CDP `Network.clearBrowserCache` 会清掉。
    _write(stateRoot, 'webview2/EBWebView/Default/Cache/data_0', 100);
    _write(
      stateRoot,
      'webview2/EBWebView/Default/Cache/Cache_Data/f_000001',
      50,
    );
    // GPU / Shader / Dawn / Code Cache 是运行时组件，CDP 不清，不得计入。
    _write(stateRoot, 'webview2/EBWebView/Default/Code Cache/js/data_0', 20);
    _write(stateRoot, 'webview2/EBWebView/Default/GPUCache/data_0', 25);
    _write(stateRoot, 'webview2/EBWebView/Default/DawnCache/data_0', 10);
    _write(stateRoot, 'webview2/EBWebView/Default/GrShaderCache/data_0', 10);
    _write(stateRoot, 'webview2/EBWebView/Default/ShaderCache/data_0', 10);
    _write(stateRoot, 'webview2/EBWebView/GrShaderCache/data_0', 10);
    _write(stateRoot, 'webview2/EBWebView/ShaderCache/data_0', 10);
    // 漫画 profile 的当前目录。
    _write(stateRoot, 'webview2-manga/EBWebView/Default/Cache/data_0', 200);
    // 旧代理参数留下的兄弟目录：当前环境不会清理它，不得计入占用。
    _write(
      stateRoot,
      'webview2-manga-ab12/EBWebView/Default/Cache/data_0',
      300,
    );
    // 登录态与站点数据绝不计入占用。
    _write(stateRoot, 'webview2/EBWebView/Default/Network/Cookies', 999);
    _write(
      stateRoot,
      'webview2/EBWebView/Default/Local Storage/leveldb/000003.log',
      999,
    );
    _write(stateRoot, 'webview2/EBWebView/Default/IndexedDB/source/LOG', 999);
    _write(stateRoot, 'webview2/EBWebView/Default/Preferences', 999);

    final MangaWebViewCacheClearStep step = MangaWebViewCacheClearStep(
      id: 'webview_http',
      label: 'WebView cache',
      profiles: buildMangaWebViewCacheProfiles(stateRoot: stateRoot),
    );

    expect(
      await step.measureBytes(),
      350,
      reason: '只统计当前环境的 HTTP cache：150 默认 + 200 漫画；'
          '旧 webview2-manga-ab12 的 300 不再被清理，不能计入',
    );
  });

  test('测量跟随当前漫画环境目录，而不是汇总全部 webview2-manga* 兄弟', () async {
    final Directory stateRoot = Directory.systemTemp.createTempSync(
      'manga_webview_active_',
    );
    addTearDown(() {
      if (stateRoot.existsSync()) stateRoot.deleteSync(recursive: true);
    });
    _write(stateRoot, 'webview2/EBWebView/Default/Cache/data_0', 100);
    _write(stateRoot, 'webview2-manga/EBWebView/Default/Cache/data_0', 200);
    _write(
      stateRoot,
      'webview2-manga-ab12/EBWebView/Default/Cache/data_0',
      300,
    );
    // 换代理参数后 environment 落到派生兄弟目录：只有它会被清理。
    final Directory active = Directory(
      p.join(stateRoot.path, 'webview2-manga-ab12'),
    );
    MangaWebViewEnvironment.debugSetCurrentUserDataFolder(active.path);

    final MangaWebViewCacheClearStep step = MangaWebViewCacheClearStep(
      id: 'webview_http',
      label: 'WebView cache',
      profiles: buildMangaWebViewCacheProfiles(stateRoot: stateRoot),
    );

    expect(
      await step.measureBytes(),
      400,
      reason: '100 默认 + 300 当前 manga 环境；基础 webview2-manga 的 200 是旧目录',
    );
  });

  test('WebView 清理返回真实释放字节', () async {
    final Directory stateRoot = Directory.systemTemp.createTempSync(
      'manga_webview_freed_',
    );
    addTearDown(() {
      if (stateRoot.existsSync()) stateRoot.deleteSync(recursive: true);
    });

    _write(stateRoot, 'webview2/EBWebView/Default/Cache/data_0', 100);
    _write(
      stateRoot,
      'webview2/EBWebView/Default/Cache/Cache_Data/f_000001',
      50,
    );
    _write(stateRoot, 'webview2-manga/EBWebView/Default/Cache/data_0', 200);
    final Directory defaultFolder = Directory(
      p.join(stateRoot.path, 'webview2'),
    );
    final Directory mangaFolder = Directory(
      p.join(stateRoot.path, 'webview2-manga'),
    );
    final Directory defaultHttpCache = Directory(
      p.join(defaultFolder.path, 'EBWebView', 'Default', 'Cache'),
    );
    final Directory mangaHttpCache = Directory(
      p.join(mangaFolder.path, 'EBWebView', 'Default', 'Cache'),
    );
    Future<void> deleteHttpCache(Directory cache) async {
      if (await cache.exists()) await cache.delete(recursive: true);
    }

    final MangaWebViewCacheClearStep step = MangaWebViewCacheClearStep(
      id: 'webview_http',
      label: 'WebView cache',
      profiles: <MangaWebViewCacheProfile>[
        MangaWebViewCacheProfile(
          id: 'default',
          sessionSource: MangaWebViewCacheSessionSource(
            openHeadless: () async => _FakeSession(
              'default',
              onClear: () => deleteHttpCache(defaultHttpCache),
            ),
          ),
          cacheDirectories: mangaWebViewClearableCacheDirectories(defaultFolder),
        ),
        MangaWebViewCacheProfile(
          id: 'manga',
          sessionSource: MangaWebViewCacheSessionSource(
            openHeadless: () async => _FakeSession(
              'manga',
              onClear: () => deleteHttpCache(mangaHttpCache),
            ),
          ),
          cacheDirectories: mangaWebViewClearableCacheDirectories(mangaFolder),
        ),
      ],
    );

    expect(await step.measureBytes(), 350);
    final MangaCacheClearStepResult result = await step.clear();

    expect(result.freedBytes, 350, reason: '释放量必须是清理前后的真实差异');
    expect(result.failedEntries, 0);
    expect(await step.measureBytes(), 0, reason: 'WebView HTTP cache 已清空');
  });

  test('单个 profile 失败仍返回其余 profile 的真实释放量并保留登录态与数据库', () async {
    final Directory tmp = Directory.systemTemp.createTempSync(
      'manga_webview_partial_',
    );
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final Directory stateRoot = Directory(p.join(tmp.path, 'state'))
      ..createSync(recursive: true);

    _write(tmp, 'state/webview2/EBWebView/Default/Cache/data_0', 100);
    _write(tmp, 'state/webview2-manga/EBWebView/Default/Cache/data_0', 200);
    final Directory defaultHttpCache = Directory(
      p.join(stateRoot.path, 'webview2', 'EBWebView', 'Default', 'Cache'),
    );
    final Directory mangaHttpCache = Directory(
      p.join(stateRoot.path, 'webview2-manga', 'EBWebView', 'Default', 'Cache'),
    );
    final Map<String, int> preserved = <String, int>{
      'state/webview2/EBWebView/Default/Network/Cookies': 999,
      'state/webview2/EBWebView/Default/Local Storage/leveldb/000003.log': 999,
      'state/webview2/EBWebView/Default/IndexedDB/source/LOG': 999,
      'state/webview2/EBWebView/Default/Preferences': 999,
      'state/mycomic.sqlite': 444,
      'state/logs/app.log': 555,
      'state/mihon/cookies.json': 666,
      'content/downloads/Source/Series/ch1.cbz': 777,
      'content/local/Series/cover.jpg': 888,
      'GlobalLookupWebView2/EBWebView/Default/Cache/data_0': 999,
    };
    final Map<String, File> preservedFiles = <String, File>{
      for (final MapEntry<String, int> entry in preserved.entries)
        entry.key: _write(tmp, entry.key, entry.value),
    };

    final MangaWebViewCacheClearStep step = MangaWebViewCacheClearStep(
      id: 'webview_http',
      label: 'WebView cache',
      profiles: <MangaWebViewCacheProfile>[
        MangaWebViewCacheProfile(
          id: 'default',
          sessionSource: MangaWebViewCacheSessionSource(
            openHeadless: () async =>
                _FakeSession('default', clearError: StateError('CDP failed')),
          ),
          cacheDirectories: mangaWebViewClearableCacheDirectories(
            Directory(p.join(stateRoot.path, 'webview2')),
          ),
        ),
        MangaWebViewCacheProfile(
          id: 'manga',
          sessionSource: MangaWebViewCacheSessionSource(
            openHeadless: () async => _FakeSession(
              'manga',
              onClear: () async {
                if (await mangaHttpCache.exists()) {
                  await mangaHttpCache.delete(recursive: true);
                }
              },
            ),
          ),
          cacheDirectories: mangaWebViewClearableCacheDirectories(
            Directory(p.join(stateRoot.path, 'webview2-manga')),
          ),
        ),
      ],
    );

    expect(await step.measureBytes(), 300);
    final MangaCacheClearStepResult result = await step.clear();

    expect(result.failedEntries, 1, reason: '默认 profile 失败必须报告部分成功');
    expect(result.freedBytes, 200, reason: '只计算真正清掉的漫画 profile HTTP cache');
    expect(
      MangaCacheClearReport(
        steps: <MangaCacheClearStepResult>[result],
      ).hasPartial,
      isTrue,
    );
    expect(
      defaultHttpCache.existsSync(),
      isTrue,
      reason: '失败的 profile 缓存保持原样，留给下次重试',
    );
    for (final MapEntry<String, File> entry in preservedFiles.entries) {
      expect(entry.value.existsSync(), isTrue, reason: '${entry.key} 必须保留');
      expect(entry.value.lengthSync(), preserved[entry.key], reason: entry.key);
    }
  });

  test('平台不支持 WebView 清理时跳过并在结果中体现部分成功', () async {
    int headlessOpened = 0;
    final MangaWebViewCacheClearStep step = MangaWebViewCacheClearStep(
      id: 'webview_http',
      label: 'WebView cache',
      supported: false,
      profiles: <MangaWebViewCacheProfile>[
        MangaWebViewCacheProfile(
          id: 'default',
          sessionSource: MangaWebViewCacheSessionSource(
            openHeadless: () async {
              headlessOpened++;
              return _FakeSession('default');
            },
          ),
        ),
      ],
    );

    expect(await step.measureBytes(), 0);
    final MangaCacheClearStepResult result = await step.clear();

    expect(result.skipped, isTrue);
    expect(result.failedEntries, 0);
    expect(headlessOpened, 0, reason: '不支持的平台不得创建 headless WebView');
    expect(
      MangaCacheClearReport(
        steps: <MangaCacheClearStepResult>[result],
      ).hasPartial,
      isTrue,
    );
  });

  test('某个 profile 清理失败时继续清理其余 profile 并报告部分成功', () async {
    final _FakeSession failing = _FakeSession('default')
      ..clearError = StateError('CDP unavailable');
    final _FakeSession ok = _FakeSession('manga');
    final List<String> headlessOpened = <String>[];
    final MangaWebViewCacheClearStep step = MangaWebViewCacheClearStep(
      id: 'webview_http',
      label: 'WebView cache',
      profiles: <MangaWebViewCacheProfile>[
        _profile('default', failing, headlessOpened),
        _profile('manga', ok, headlessOpened),
      ],
    );

    final MangaCacheClearStepResult result = await step.clear();

    expect(result.failedEntries, 1, reason: '单个 profile 失败应体现部分成功');
    expect(headlessOpened, <String>[
      'default',
      'manga',
    ], reason: '失败不能中断后续 profile');
    expect(ok.clearCalls, 1);
    expect(failing.disposed, isTrue, reason: '失败路径也必须销毁临时 WebView');
    expect(ok.disposed, isTrue);
  });

  test('临时 WebView 销毁失败也作为部分成功上报', () async {
    final _FakeSession session = _FakeSession('default')
      ..disposeError = StateError('dispose failed');
    final MangaWebViewCacheClearStep step = MangaWebViewCacheClearStep(
      id: 'webview_http',
      label: 'WebView cache',
      profiles: <MangaWebViewCacheProfile>[
        _profile('default', session, <String>[]),
      ],
    );

    final MangaCacheClearStepResult result = await step.clear();

    expect(session.clearCalls, 1);
    expect(result.failedEntries, 1);
  });

  test('清理 WebView 缓存不删除 WebView2 数据目录的登录态与站点数据', () async {
    final Directory tmp = Directory.systemTemp.createTempSync(
      'manga_webview_cache_',
    );
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final List<File> preserved = <File>[
      File(
        p.join(
          tmp.path,
          'state',
          'webview2',
          'EBWebView',
          'Default',
          'Network',
          'Cookies',
        ),
      ),
      File(
        p.join(
          tmp.path,
          'state',
          'webview2',
          'EBWebView',
          'Default',
          'Local Storage',
          'leveldb',
          '000003.log',
        ),
      ),
      File(
        p.join(
          tmp.path,
          'state',
          'webview2',
          'EBWebView',
          'Default',
          'IndexedDB',
          'source.indexeddb.leveldb',
          'LOCK',
        ),
      ),
      File(
        p.join(
          tmp.path,
          'state',
          'webview2',
          'EBWebView',
          'Default',
          'Preferences',
        ),
      ),
      File(
        p.join(
          tmp.path,
          'state',
          'webview2-manga',
          'EBWebView',
          'Default',
          'Network',
          'Cookies',
        ),
      ),
    ];
    for (final File file in preserved) {
      file
        ..createSync(recursive: true)
        ..writeAsStringSync('keep');
    }
    final _FakeSession defaultSession = _FakeSession('default');
    final _FakeSession mangaSession = _FakeSession('manga');
    final MangaWebViewCacheClearStep step = MangaWebViewCacheClearStep(
      id: 'webview_http',
      label: 'WebView cache',
      profiles: <MangaWebViewCacheProfile>[
        _profile('default', defaultSession, <String>[]),
        _profile('manga', mangaSession, <String>[]),
      ],
    );

    await step.clear();

    for (final File file in preserved) {
      expect(file.existsSync(), isTrue, reason: '${file.path} 必须保留');
    }
    expect(defaultSession.calls, <String>['clearHttpCache', 'dispose']);
    expect(mangaSession.calls, <String>['clearHttpCache', 'dispose']);
  });

  test('CDP 只调用 Network.clearBrowserCache，不清浏览器 cookies', () async {
    final List<String> calls = <String>[];
    final MangaWebViewCdpCacheSession session = MangaWebViewCdpCacheSession(
      profileId: 'default',
      callDevToolsProtocolMethod: (String methodName) async {
        calls.add(methodName);
      },
      disposeWebView: () async {},
    );

    await session.clearHttpCache();

    expect(calls, <String>['Network.clearBrowserCache']);
    expect(calls, isNot(contains('Network.clearBrowserCookies')));
    expect(calls, isNot(contains('Storage.clearDataForOrigin')));
  });

  test('默认步骤覆盖默认与漫画两个 WebView profile', () {
    final Directory stateRoot = Directory.systemTemp.createTempSync(
      'manga_webview_profiles_',
    );
    addTearDown(() {
      if (stateRoot.existsSync()) stateRoot.deleteSync(recursive: true);
    });
    final List<MangaWebViewCacheProfile> profiles =
        buildMangaWebViewCacheProfiles(stateRoot: stateRoot);

    expect(
      profiles.map((MangaWebViewCacheProfile profile) => profile.id).toList(),
      <String>['default', 'manga'],
    );
  });

  test('文件系统测量失败按 0 计，不阻断清理', () async {
    final _FakeSession session = _FakeSession('default');
    final MangaWebViewCacheClearStep step = MangaWebViewCacheClearStep(
      id: 'webview_http',
      label: 'WebView cache',
      profiles: <MangaWebViewCacheProfile>[
        _profile('default', session, <String>[]),
      ],
      measureDirectories: (List<Directory> _) async =>
          throw const FileSystemException('permission denied'),
    );

    expect(await step.measureBytes(), 0);
    final MangaCacheClearStepResult result = await step.clear();

    expect(result.freedBytes, 0, reason: '测量失败时无法证明释放量，按 0 计');
    expect(result.failedEntries, 0, reason: '测量失败不等于清理失败');
    expect(session.clearCalls, 1, reason: '测量失败不得跳过真正的清理');
  });

  test('意外测量异常不被「按 0 计」掩盖', () async {
    final MangaWebViewCacheClearStep step = MangaWebViewCacheClearStep(
      id: 'webview_http',
      label: 'WebView cache',
      profiles: const <MangaWebViewCacheProfile>[],
      measureDirectories: (List<Directory> _) async =>
          throw StateError('unexpected measurement bug'),
    );

    await expectLater(
      step.measureBytes(),
      throwsA(isA<StateError>()),
      reason: '只有 FileSystemException 可以降级为 0，编程错误必须暴露',
    );
  });
}

File _write(Directory root, String relative, int bytes) {
  final File file = File(
    p.joinAll(<String>[root.path, ...relative.split('/')]),
  )..createSync(recursive: true);
  file.writeAsBytesSync(List<int>.filled(bytes, 0x41));
  return file;
}

MangaWebViewCacheProfile _profile(
  String id,
  _FakeSession session,
  List<String> headlessOpened,
) {
  return MangaWebViewCacheProfile(
    id: id,
    sessionSource: MangaWebViewCacheSessionSource(
      openHeadless: () async {
        headlessOpened.add(id);
        return session;
      },
    ),
  );
}

class _FakeSession implements MangaWebViewCacheSession {
  _FakeSession(this.profileId, {this.clearError, this.onClear});

  @override
  final String profileId;

  final List<String> calls = <String>[];
  Error? clearError;
  Error? disposeError;

  /// 模拟 CDP 真正清掉该 profile 的 HTTP cache 目录内容。
  final Future<void> Function()? onClear;

  int get clearCalls => calls.where((String c) => c == 'clearHttpCache').length;

  bool get disposed => calls.contains('dispose');

  @override
  Future<void> clearHttpCache() async {
    calls.add('clearHttpCache');
    final Error? error = clearError;
    if (error != null) throw error;
    await onClear?.call();
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    final Error? error = disposeError;
    if (error != null) throw error;
  }
}
