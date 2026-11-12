import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/utils/adaptive/adaptive_platform.dart';
import 'package:my_comic/src/utils/components/my_comic_placeholder_message.dart';
import 'package:my_comic/src/utils/components/glass/my_comic_glass_buttons.dart';

void main() {
  for (final bool apple in <bool>[false, true]) {
    for (final double textScale in <double>[1, 2]) {
      testWidgets(
        'short placeholder scrolls to retry apple=$apple text=$textScale',
        (WidgetTester tester) async {
          await tester.binding.setSurfaceSize(const Size(420, 280));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          int retries = 0;
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                extensions: <ThemeExtension<dynamic>>[
                  MyComicGlassTheme(MyComicGlassMaterial.off, glassDesign: apple),
                ],
              ),
              home: Scaffold(
                body: MediaQuery(
                  data: MediaQueryData(
                    textScaler: TextScaler.linear(textScale),
                  ),
                  child: MyComicPlaceholderMessage(
                    icon: Icons.error_outline,
                    message: 'Unable to search Nyaa',
                    details: const <String>[
                      'The search service could not complete this request.',
                      'Check the configured proxy and retry the search.',
                      'Network request failed while loading search results.',
                    ],
                    action: MyComicTextButton(
                      onPressed: () => retries++,
                      child: const Text('Retry'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(find.text('Retry'));
          await tester.pumpAndSettle();
          expect(find.text('Retry').hitTestable(), findsOneWidget);
          await tester.tap(find.text('Retry'));
          expect(retries, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
