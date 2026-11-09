import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/manga_cache_clear_service.dart';
import 'package:fushi/src/storage/manga_webview_cache_clear.dart';

/// Ticket 12：清除缓存里的 WebView / HTTP 缓存步骤。
///
/// 只通过可控 fake 验证：默认与漫画 WebView profile 都通过 CDP
/// `Network.clearBrowserCache` 清 HTTP 缓存；临时 headless WebView 用完即销毁；
/// 某个 profile 失败时继续清其余 profile 并报告部分成功；绝不删除 WebView2
/// 数据目录（cookies / localStorage / IndexedDB / Preferences 保留）。
void main() {
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

  test('存在可见 WebView 时复用它的会话，不创建 headless WebView', () async {
    final _FakeSession visible = _FakeSession('manga');
    int headlessOpened = 0;
    final MangaWebViewCacheClearStep step = MangaWebViewCacheClearStep(
      id: 'webview_http',
      label: 'WebView cache',
      profiles: <MangaWebViewCacheProfile>[
        MangaWebViewCacheProfile(
          id: 'manga',
          sessionSource: MangaWebViewCacheSessionSource(
            findVisible: () async => visible,
            openHeadless: () async {
              headlessOpened++;
              return _FakeSession('manga');
            },
          ),
        ),
      ],
    );

    final MangaCacheClearStepResult result = await step.clear();

    expect(result.failedEntries, 0);
    expect(headlessOpened, 0, reason: '有可见 WebView 时不应再建 headless');
    expect(visible.clearCalls, 1);
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
    final List<MangaWebViewCacheProfile> profiles =
        buildMangaWebViewCacheProfiles();

    expect(
      profiles.map((MangaWebViewCacheProfile profile) => profile.id).toList(),
      <String>['default', 'manga'],
    );
  });
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
  _FakeSession(this.profileId);

  @override
  final String profileId;

  final List<String> calls = <String>[];
  Error? clearError;
  Error? disposeError;

  int get clearCalls => calls.where((String c) => c == 'clearHttpCache').length;

  bool get disposed => calls.contains('dispose');

  @override
  Future<void> clearHttpCache() async {
    calls.add('clearHttpCache');
    final Error? error = clearError;
    if (error != null) throw error;
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    final Error? error = disposeError;
    if (error != null) throw error;
  }
}
