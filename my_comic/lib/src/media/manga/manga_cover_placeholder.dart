import 'package:material_ui/material_ui.dart';

import 'package:my_comic/src/utils/components/glass/my_comic_icon.dart';
import 'package:my_comic/src/utils/my_comic_icons.dart';

/// 漫画封面缺图 / 解码失败时的统一占位块：跟随主题的中性底（深浅色都可读），
/// 不再是写死的深灰 #303030（浅色主题下是突兀的黑块、图标也看不清）。
///
/// 本地图源浏览网格与 Manga 作品页共用，保证两处形态一致。
class MangaCoverPlaceholder extends StatelessWidget {
  const MangaCoverPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return ColoredBox(
      color: cs.surfaceContainerHighest,
      child: Center(
        child: MyComicIcon(
          MyComicIcons.manga,
          size: 40,
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}
