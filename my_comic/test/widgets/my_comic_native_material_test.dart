import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/utils/adaptive/adaptive_platform.dart';
import 'package:my_comic/src/utils/components/my_comic_material_components.dart';
import 'package:my_comic/src/utils/components/glass/my_comic_native_material.dart';
import 'package:my_comic/src/utils/system_transparency.dart';

ThemeData _theme({
  TargetPlatform platform = TargetPlatform.macOS,
  bool glassDesign = false,
  MyComicGlassMaterial material = MyComicGlassMaterial.off,
  bool eink = false,
  Brightness brightness = Brightness.dark,
}) {
  return ThemeData(
    platform: platform,
    brightness: brightness,
    extensions: <ThemeExtension<dynamic>>[
      MyComicGlassTheme(material, glassDesign: glassDesign),
      MyComicEinkTheme(eink),
    ],
  );
}

void main() {
  late bool Function() savedHost;

  setUp(() {
    savedHost = debugNativeMaterialHostSupported;
    debugNativeMaterialHostSupported = () => true;
    SystemTransparency.reduceTransparency.value = false;
  });

  tearDown(() {
    debugNativeMaterialHostSupported = savedHost;
    SystemTransparency.reduceTransparency.value = false;
  });

  group('myComicNativePopupMaterialAvailable', () {
    test('MD3 on macOS / iOS: available unless reduce transparency', () {
      for (final TargetPlatform p in <TargetPlatform>[
        TargetPlatform.macOS,
        TargetPlatform.iOS,
      ]) {
        expect(
          myComicNativePopupMaterialAvailable(
            theme: _theme(platform: p),
            highContrast: false,
          ),
          isTrue,
        );
      }
      SystemTransparency.reduceTransparency.value = true;
      expect(
        myComicNativePopupMaterialAvailable(theme: _theme(), highContrast: false),
        isFalse,
      );
    });

    test('glass design follows its material tier', () {
      expect(
        myComicNativePopupMaterialAvailable(
          theme: _theme(glassDesign: true),
          highContrast: false,
        ),
        isFalse,
      );
      expect(
        myComicNativePopupMaterialAvailable(
          theme: _theme(
            glassDesign: true,
            material: MyComicGlassMaterial.frosted,
          ),
          highContrast: false,
        ),
        isTrue,
      );
    });

    test('eink / high contrast / other platforms / no native host: off', () {
      expect(
        myComicNativePopupMaterialAvailable(
          theme: _theme(eink: true),
          highContrast: false,
        ),
        isFalse,
      );
      expect(
        myComicNativePopupMaterialAvailable(theme: _theme(), highContrast: true),
        isFalse,
      );
      for (final TargetPlatform p in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.android,
        TargetPlatform.linux,
      ]) {
        expect(
          myComicNativePopupMaterialAvailable(
            theme: _theme(platform: p),
            highContrast: false,
          ),
          isFalse,
        );
      }
      debugNativeMaterialHostSupported = () => false;
      expect(
        myComicNativePopupMaterialAvailable(theme: _theme(), highContrast: false),
        isFalse,
      );
    });
  });

  testWidgets('popup surface over a platform view puts the native material '
      'behind its child on macOS', (WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (MethodCall call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: const Center(
          child: SizedBox(
            width: 300,
            height: 200,
            child: MyComicPopupSurface(
              borderOnForeground: false,
              child: SizedBox.expand(key: ValueKey<String>('popup-child')),
            ),
          ),
        ),
      ),
    );
    final Finder backdrop = find.byType(MyComicNativeMaterialBackdrop);
    expect(backdrop, findsOneWidget);
    expect(find.byType(AppKitView), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    // 背衬铺满整块 surface，子节点沿描边内缩 1px（BUG-2166）。
    final Offset backdropTopLeft = tester.getTopLeft(backdrop);
    expect(
      backdropTopLeft,
      tester.getTopLeft(find.byKey(const ValueKey<String>('popup-child'))) -
          const Offset(1, 1),
    );
  });

  testWidgets('without native host the panel stays opaque (no native view)', (
    WidgetTester tester,
  ) async {
    debugNativeMaterialHostSupported = () => false;
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: const Center(
          child: SizedBox(
            width: 300,
            height: 200,
            child: MyComicPopupSurface(
              borderOnForeground: false,
              child: SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(MyComicNativeMaterialBackdrop), findsNothing);
    expect(find.byType(AppKitView), findsNothing);
  });
}
