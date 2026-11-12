import 'package:material_ui/material_ui.dart';
import 'package:my_comic/src/utils/components/glass/my_comic_icon.dart';
import 'package:gap/gap.dart';
import 'package:my_comic/utils.dart';

/// Used for various dialogs, such as the dictionary, profiles and enhancements
/// menus. Used for listing, selecting and reordering items.
class MyComicListTile extends StatelessWidget {
  /// Initialise this widget.
  const MyComicListTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selected,
    this.foregroundColor,
    this.onTap,
    this.trailing,
    super.key,
  });

  /// Whether or not this title is currently selected.
  final bool selected;

  /// The primary text of this tile.
  final String title;

  /// The secondary text of this tile.
  final String subtitle;

  /// The icon to show as the leading content of this tile.
  final IconData icon;

  /// The foreground color affecting the text and icon of this tile.
  final Color? foregroundColor;

  /// The action to perform if this tile is tapped.
  final Function()? onTap;

  /// Widget shown at the end of the tile. Shown only when selected.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return MyComicListItem(
      selected: selected,
      onTap: onTap,
      leading: MyComicIcon(
        icon,
        color: foregroundColor,
      ),
      title: MyComicMarquee(
        text: title,
        style:
            foregroundColor == null ? null : TextStyle(color: foregroundColor),
      ),
      subtitle: MyComicMarquee(
        text: subtitle,
        style:
            foregroundColor == null ? null : TextStyle(color: foregroundColor),
      ),
      trailing: trailing != null && selected
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                trailing!,
                const Gap(6),
              ],
            )
          : const Gap(6),
    );
  }
}
