import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/media/manga/mihon/desktop_mihon_runtime.dart';
import 'package:my_comic/src/media/manga/mihon/mihon_models.dart';

void main() {
  group('M-Extension-Server sidecar contract', () {
    test('sends both MyComic and frozen legacy environment names', () {
      final Map<String, String> env =
          DesktopMihonRuntime.buildSidecarEnvironment(
            token: 'test-token',
            proxyPolicyPort: 4321,
          );

      expect(env['MYCOMIC_MIHON_TOKEN'], 'test-token');
      expect(env['FUSHI_MIHON_TOKEN'], 'test-token');
      expect(env['MYCOMIC_MIHON_PROXY_POLICY_PORT'], '4321');
      expect(env['FUSHI_MIHON_PROXY_POLICY_PORT'], '4321');
    });

    test('parses the pinned sidecar capabilities key', () {
      final MihonCapabilities capabilities = MihonCapabilities.fromJson(
        const <String, Object?>{
          'fushiMihonBridge': 1,
          'sourceFactory': true,
          'preferenceCallbacks': true,
          'imageProxy': true,
          'sourceUrls': true,
          'hostProxyPolicy': true,
        },
      );

      expect(capabilities.isUsable, isTrue);
    });

    test('accepts both ready-line markers', () {
      expect(
        DesktopMihonRuntime.parseReadyPort('FUSHI_MIHON_READY port=12484'),
        12484,
      );
      expect(
        DesktopMihonRuntime.parseReadyPort('MYCOMIC_MIHON_READY port=12484'),
        12484,
      );
      expect(
        DesktopMihonRuntime.parseReadyPort(
          'log FUSHI_MIHON_READY port=1 trailing',
        ),
        1,
      );
      expect(DesktopMihonRuntime.parseReadyPort('nothing here'), isNull);
      expect(
        DesktopMihonRuntime.parseReadyPort('FUSHI_MIHON_READY port=0'),
        isNull,
      );
      expect(
        DesktopMihonRuntime.parseReadyPort('FUSHI_MIHON_READY port=70000'),
        isNull,
      );
    });
  });
}
