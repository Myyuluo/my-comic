import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/media/online/online_work_detail.dart';
import 'package:my_comic/src/utils/components/my_comic_material_components.dart';

/// 三域共用作品页头部的版式契约（PR #1707 审查）：窄屏时封面右边只剩一百多
/// 像素，主操作区放在那里每个按钮都独占一行、竖着堆成一长条——窄宽时操作区要
/// 挪到封面行下方、占满整宽横排；宽屏仍在封面右侧。
void main() {
  Future<void> pumpHeader(WidgetTester tester, double width) async {
    await tester.binding.setSurfaceSize(Size(width, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // 与生产同形：头部是 M3E MediaDetailHero，作为 MediaDetailLayout 的
          // header 通栏铺开、自带页边距（spacing.page）；外面再套一层 16 的列表
          // 内边距是旧版（头部不自带边距）的宿主形状，会把窄屏可用宽度多吃掉
          // 32，测的就不是真实版式了。
          body: ListView(
            padding: EdgeInsets.zero,
            children: <Widget>[
              OnlineWorkHeader(
                cover: const ColoredBox(
                  key: ValueKey<String>('cover'),
                  color: Colors.grey,
                ),
                title: 'Work title',
                actions: <Widget>[
                  FilledButton(
                    key: const ValueKey<String>('a'),
                    onPressed: () {},
                    child: const Text('Read'),
                  ),
                  OutlinedButton(
                    key: const ValueKey<String>('b'),
                    onPressed: () {},
                    child: const Text('Add'),
                  ),
                  OutlinedButton(
                    key: const ValueKey<String>('c'),
                    onPressed: () {},
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Rect rectOf(WidgetTester tester, String key) =>
      tester.getRect(find.byKey(ValueKey<String>(key)));

  testWidgets('窄屏：主操作区在封面下方横排，不竖堆', (WidgetTester tester) async {
    await pumpHeader(tester, 360);
    final Rect cover = rectOf(tester, 'cover');
    final Rect a = rectOf(tester, 'a');
    final Rect b = rectOf(tester, 'b');
    final Rect c = rectOf(tester, 'c');
    expect(a.top, greaterThanOrEqualTo(cover.bottom));
    expect(a.left, lessThan(cover.right), reason: '占满整宽，从左边起排');
    expect(b.top, a.top, reason: '同一行横排');
    expect(c.top, a.top, reason: '同一行横排');
  });

  testWidgets('宽屏：主操作区仍在封面右侧', (WidgetTester tester) async {
    await pumpHeader(tester, 1000);
    final Rect cover = rectOf(tester, 'cover');
    final Rect a = rectOf(tester, 'a');
    expect(a.left, greaterThan(cover.right));
    expect(a.top, lessThan(cover.bottom));
  });

  Future<void> pumpGenreHeader(
    WidgetTester tester, {
    required List<String> genres,
    ValueChanged<String>? onGenreTap,
    int? maxGenres = 8,
    bool useDefaultMaxGenres = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const Widget cover = ColoredBox(
      key: ValueKey<String>('cover'),
      color: Colors.grey,
    );
    // useDefaultMaxGenres = 不传该参数，验证构造器的默认上限（其他作品页）。
    final Widget header = useDefaultMaxGenres
        ? OnlineWorkHeader(
            cover: cover,
            title: 'Work title',
            genres: genres,
            onGenreTap: onGenreTap,
          )
        : OnlineWorkHeader(
            cover: cover,
            title: 'Work title',
            genres: genres,
            maxGenres: maxGenres,
            onGenreTap: onGenreTap,
          );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(padding: EdgeInsets.zero, children: <Widget>[header]),
        ),
      ),
    );
  }

  final List<String> tenGenres = <String>[
    for (int i = 1; i <= 10; i++) 'Genre $i',
  ];

  testWidgets('默认最多渲染 8 个源分类（其他作品页保持原版上限）', (WidgetTester tester) async {
    await pumpGenreHeader(
      tester,
      genres: tenGenres,
      useDefaultMaxGenres: true,
    );

    expect(
      find.byType(MyComicTagChip),
      findsNWidgets(8),
      reason: '不传 maxGenres 时沿用原版最多 8 个（小说作品页等既有调用方）',
    );
    for (final String genre in tenGenres.take(8)) {
      expect(find.text(genre), findsOneWidget);
    }
    expect(find.text('Genre 9'), findsNothing);
    expect(find.text('Genre 10'), findsNothing);
  });

  testWidgets('maxGenres = null 时源分类全部渲染，不传回调时保持纯展示', (
    WidgetTester tester,
  ) async {
    await pumpGenreHeader(tester, genres: tenGenres, maxGenres: null);

    expect(
      find.byType(MyComicTagChip),
      findsNWidgets(10),
      reason: '漫画作品页不截断：来源给多少就渲染多少',
    );
    for (final String genre in tenGenres) {
      expect(find.text(genre), findsOneWidget);
    }
    expect(
      find.descendant(
        of: find.widgetWithText(MyComicTagChip, 'Genre 1'),
        matching: find.byType(InkWell),
      ),
      findsNothing,
      reason: 'null 回调 = 纯展示：不挂可点击 / 悬停反馈',
    );

    await tester.tap(find.text('Genre 1'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('每个源分类可点击，以分类文字回调；共用 chip 的悬停 / 焦点反馈', (
    WidgetTester tester,
  ) async {
    final List<String> tapped = <String>[];
    await pumpGenreHeader(
      tester,
      genres: tenGenres,
      maxGenres: null,
      onGenreTap: tapped.add,
    );

    for (final String genre in <String>['Genre 1', 'Genre 6', 'Genre 10']) {
      final Finder chip = find.widgetWithText(MyComicTagChip, genre);
      expect(
        find.descendant(of: chip, matching: find.byType(InkWell)),
        findsOneWidget,
        reason: '$genre 接入可点击标签的悬停 / 焦点反馈',
      );
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pump();
    }

    expect(tapped, <String>['Genre 1', 'Genre 6', 'Genre 10']);
  });

  testWidgets('源分类悬停提亮，鼠标指针保持默认', (WidgetTester tester) async {
    await pumpGenreHeader(
      tester,
      genres: const <String>['奇幻'],
      maxGenres: null,
      onGenreTap: (_) {},
    );

    final Finder chip = find.widgetWithText(MyComicTagChip, '奇幻');
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();

    Color? chipColor() {
      final Finder container = find
          .descendant(of: chip, matching: find.byType(AnimatedContainer))
          .first;
      final BoxDecoration decoration =
          tester.widget<AnimatedContainer>(container).decoration!
              as BoxDecoration;
      return decoration.color;
    }

    final Color? before = chipColor();
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(chip));
    await tester.pumpAndSettle();

    expect(chipColor(), isNot(before), reason: '悬停应把底色提亮');
    expect(
      tester
          .widget<InkWell>(
            find.descendant(of: chip, matching: find.byType(InkWell)),
          )
          .mouseCursor,
      SystemMouseCursors.basic,
      reason: '与作者名 hover 一致：指针保持默认箭头',
    );
  });
}
