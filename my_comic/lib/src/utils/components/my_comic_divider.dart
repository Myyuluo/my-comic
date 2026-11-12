import 'package:material_ui/material_ui.dart';
import 'package:my_comic/src/utils/adaptive/adaptive_platform.dart';
import 'package:my_comic/src/utils/components/glass/my_comic_glass_controls.dart';

/// A standard theme divider for use across the applicaton.
class MyComicDivider extends StatelessWidget {
  /// Build a standard themed divider.
  const MyComicDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: MyComicDividerControl(
        height: 1,
        thickness: isCupertinoPlatform(context) ? 0.33 : 0.5,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
    );
  }
}
