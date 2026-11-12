import 'package:material_ui/material_ui.dart';
import 'package:my_comic/src/utils/adaptive/adaptive_platform.dart';
import 'package:my_comic/src/utils/adaptive/adaptive_widgets.dart';
import 'package:my_comic/src/utils/components/glass/my_comic_glass_lists.dart'
    show MyComicAppleCheckmark;
import 'package:my_comic/src/utils/components/glass/my_comic_icon.dart';
import 'package:my_comic/src/utils/components/settings_shared.dart';

/// One selectable (value, label) entry for [MyComicOptionSelectionPage].
class MyComicOptionSelectionOption<T> {
  const MyComicOptionSelectionOption({required this.value, required this.label});

  final T value;
  final String label;
}

/// Pushes a [MyComicOptionSelectionPage] and resolves to the chosen value, or
/// null when the user backs out without picking.
Future<T?> pickOption<T>(
  BuildContext context, {
  required String title,
  required List<MyComicOptionSelectionOption<T>> options,
  required T? selected,
}) {
  return Navigator.of(context).push<T>(
    // Adaptive route so iOS/macOS get the Cupertino transition + swipe-back
    // gesture (the page body already adapts via AdaptiveSettingsScaffold).
    adaptivePageRoute<T>(
      context: context,
      builder: (_) => MyComicOptionSelectionPage<T>(
        title: title,
        options: options,
        selected: selected,
      ),
    ),
  );
}

/// A bounded, full-page single-choice list. Replaces anchored overlay dropdowns
/// (DropdownMenu / MenuAnchor / CupertinoActionSheet) for option sets large
/// enough to overflow the screen: the page is a normal scrollable
/// [AdaptiveSettingsScaffold], so every entry is reachable and the last option
/// can never be clipped off the bottom. The selected entry shows a trailing
/// check; tapping any other entry pops the page with that entry's value.
class MyComicOptionSelectionPage<T> extends StatelessWidget {
  const MyComicOptionSelectionPage({
    required this.title,
    required this.options,
    required this.selected,
    super.key,
  });

  final String title;
  final List<MyComicOptionSelectionOption<T>> options;
  final T? selected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    // Single-choice list: the selected entry shows a trailing check, every
    // other entry is a plain tappable row. No navigation chevron — tapping an
    // option pops this page with its value, it does not drill into a subpage,
    // so a `chevron_right` would falsely imply a deeper level.
    // Apple 选择列表：行尾是强调色细对勾（iOS 设置的单选口径）。
    final bool apple = isGlassDesign(context);
    final List<Widget> rows = options.map((MyComicOptionSelectionOption<T> o) {
      final bool isSelected = o.value == selected;
      return AdaptiveSettingsRow(
        title: o.label,
        trailing: !isSelected
            ? null
            : apple
                ? const MyComicAppleCheckmark()
                : MyComicIcon(Icons.check, color: scheme.primary),
        onTap: isSelected ? null : () => Navigator.pop(context, o.value),
      );
    }).toList();

    return AdaptiveSettingsScaffold(
      title: Text(title),
      children: <Widget>[
        AdaptiveSettingsSection(children: rows),
      ],
    );
  }
}
