import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/media/manga/manga_reading_mode.dart';
import 'package:my_comic/src/media/manga/manga_reader_preferences.dart';
import 'package:my_comic/src/media/manga/manga_spread_model.dart';
import 'package:my_comic/src/pages/implementations/manga_my_comic_page.dart';
import 'package:my_comic_engine/media/manga/mokuro_payload.dart';

void main() {
  test(
    'resetting book mode returns to legacy or global/automatic defaults',
    () {
      const MokuroPayload tallPages = MokuroPayload(
        images: <MokuroImage>[
          MokuroImage(
            url: 'p.jpg',
            size: MokuroSize(800, 4000),
            blocks: <MokuroBlock>[],
          ),
        ],
      );
      expect(
        MangaMyComicPage.resolveReaderMode(
          preferences: const MangaReaderPreferences(
            mode: MangaReadingMode.pagedVertical,
          ),
          payload: tallPages,
          hasModeOverride: true,
          legacyMode: 'spread',
        ),
        MangaReadingMode.pagedVertical,
      );
      expect(
        MangaMyComicPage.resolveReaderMode(
          preferences: const MangaReaderPreferences(
            mode: MangaReadingMode.webtoonGaps,
          ),
          payload: tallPages,
          hasModeOverride: false,
          legacyMode: 'spread',
        ),
        MangaReadingMode.spread,
      );
      expect(
        MangaMyComicPage.resolveReaderMode(
          preferences: const MangaReaderPreferences(
            mode: MangaReadingMode.webtoonGaps,
          ),
          payload: tallPages,
          hasModeOverride: false,
        ),
        MangaReadingMode.webtoonGaps,
      );
      expect(
        MangaMyComicPage.resolveReaderMode(
          preferences: const MangaReaderPreferences(autoMode: true),
          payload: tallPages,
          hasModeOverride: false,
        ),
        MangaReadingMode.webtoon,
      );
    },
  );
  group('mangaWindowRange', () {
    test('窗口在起点被 clamp', () {
      expect(
        MangaMyComicPage.mangaWindowRange(spreadCount: 10, current: 0, radius: 1),
        <int>[0, 1],
      );
    });

    test('窗口居中', () {
      expect(
        MangaMyComicPage.mangaWindowRange(spreadCount: 10, current: 5, radius: 1),
        <int>[4, 5, 6],
      );
    });

    test('窗口在终点被 clamp', () {
      expect(
        MangaMyComicPage.mangaWindowRange(spreadCount: 10, current: 9, radius: 1),
        <int>[8, 9],
      );
    });

    test('单 spread 书绝不越界', () {
      expect(
        MangaMyComicPage.mangaWindowRange(spreadCount: 1, current: 0, radius: 2),
        <int>[0],
      );
    });

    test('零页书回空', () {
      expect(
        MangaMyComicPage.mangaWindowRange(spreadCount: 0, current: 0, radius: 1),
        isEmpty,
      );
    });
  });

  group('spread index <-> page', () {
    test('double 布局无偏移：0/1、2/3 配对', () {
      final List<MangaSpreadEntry> spreads = buildMangaSpreads(
        4,
        layout: MangaPageLayout.double,
        spreadOffset: 0,
      );
      expect(MangaMyComicPage.firstPageOfSpread(spreads, 0), 0);
      expect(MangaMyComicPage.firstPageOfSpread(spreads, 1), 2);
      expect(MangaMyComicPage.spreadIndexForPage(spreads, 3), 1);
    });

    test('single 布局：spread 序号 == 页码', () {
      final List<MangaSpreadEntry> spreads = buildMangaSpreads(
        3,
        layout: MangaPageLayout.single,
        spreadOffset: 0,
      );
      for (int i = 0; i < 3; i++) {
        expect(MangaMyComicPage.firstPageOfSpread(spreads, i), i);
        expect(MangaMyComicPage.spreadIndexForPage(spreads, i), i);
      }
    });
  });

  group('mangaProgressForSpread', () {
    final List<MangaSpreadEntry> spreads = buildMangaSpreads(
      6,
      layout: MangaPageLayout.double,
      spreadOffset: 0,
    );

    test('spread 模式落 spread 首页页码，fraction 钉 0', () {
      final (int page, double fraction) = MangaMyComicPage.mangaProgressForSpread(
        spreads,
        2,
        webtoonFraction: 0.5,
        isWebtoon: false,
      );
      expect(page, 4); // spread 2 -> pages 4/5
      expect(fraction, 0.0);
    });

    test('webtoon 模式落 top 页 + 页内 fraction', () {
      final (int page, double fraction) = MangaMyComicPage.mangaProgressForSpread(
        spreads,
        2,
        webtoonFraction: 0.5,
        isWebtoon: true,
      );
      expect(page, 4);
      expect(fraction, 0.5);
    });
  });

  group('restoreSpreadFromProgress', () {
    final List<MangaSpreadEntry> spreads = buildMangaSpreads(
      6,
      layout: MangaPageLayout.double,
      spreadOffset: 0,
    );

    test('持久化页码映射回所属 spread', () {
      expect(MangaMyComicPage.restoreSpreadFromProgress(spreads, 4), 2);
      expect(MangaMyComicPage.restoreSpreadFromProgress(spreads, 5), 2);
      expect(MangaMyComicPage.restoreSpreadFromProgress(spreads, 0), 0);
    });

    test('越界存档 clamp 到末 spread', () {
      expect(
        MangaMyComicPage.restoreSpreadFromProgress(spreads, 999),
        spreads.length - 1,
      );
    });

    test('空书回 0', () {
      expect(
        MangaMyComicPage.restoreSpreadFromProgress(const <MangaSpreadEntry>[], 3),
        0,
      );
    });
  });

  group('阅读模式覆盖', () {
    test('toggleMangaMode 双向翻转', () {
      expect(
        MangaMyComicPage.toggleMangaMode(MangaReadingMode.spread),
        MangaReadingMode.webtoon,
      );
      expect(
        MangaMyComicPage.toggleMangaMode(MangaReadingMode.webtoon),
        MangaReadingMode.spread,
      );
    });

    test('模式 <-> DB 字符串双向映射', () {
      expect(MangaMyComicPage.modeToDbString(MangaReadingMode.spread), 'spread');
      expect(
        MangaMyComicPage.modeToDbString(MangaReadingMode.webtoon),
        'webtoon',
      );
      expect(
        MangaMyComicPage.modeFromDbString('webtoon'),
        MangaReadingMode.webtoon,
      );
      expect(
        MangaMyComicPage.modeFromDbString('spread'),
        MangaReadingMode.spread,
      );
      expect(MangaMyComicPage.modeFromDbString('???'), MangaReadingMode.spread);
    });

    test('modeOverrideFromDb：null/空 = 自动判定（回 null）', () {
      expect(MangaMyComicPage.modeOverrideFromDb(null), isNull);
      expect(MangaMyComicPage.modeOverrideFromDb(''), isNull);
      expect(
        MangaMyComicPage.modeOverrideFromDb('spread'),
        MangaReadingMode.spread,
      );
      expect(
        MangaMyComicPage.modeOverrideFromDb('webtoon'),
        MangaReadingMode.webtoon,
      );
    });
  });

  group('webtoon fraction <-> charOffset（千分比 0..1000）', () {
    test('往返换算', () {
      expect(MangaMyComicPage.webtoonFractionToCharOffset(0), 0);
      expect(MangaMyComicPage.webtoonFractionToCharOffset(0.5), 500);
      expect(MangaMyComicPage.webtoonFractionToCharOffset(1.0), 1000);
      expect(MangaMyComicPage.charOffsetToWebtoonFraction(500), 0.5);
      expect(MangaMyComicPage.charOffsetToWebtoonFraction(1000), 1.0);
    });

    test('脏值容错（越界/负值/null clamp）', () {
      expect(MangaMyComicPage.webtoonFractionToCharOffset(-0.5), 0);
      expect(MangaMyComicPage.webtoonFractionToCharOffset(1.5), 1000);
      expect(MangaMyComicPage.charOffsetToWebtoonFraction(null), 0);
      expect(MangaMyComicPage.charOffsetToWebtoonFraction(-1), 0);
      expect(MangaMyComicPage.charOffsetToWebtoonFraction(99999), 1.0);
    });

    test('恢复语义：round-trip 后落回同一 fraction（千分之一精度）', () {
      for (final double f in <double>[0.0, 0.123, 0.5, 0.999, 1.0]) {
        final int stored = MangaMyComicPage.webtoonFractionToCharOffset(f);
        final double restored = MangaMyComicPage.charOffsetToWebtoonFraction(
          stored,
        );
        expect(
          (restored - f).abs() <= 0.0005,
          isTrue,
          reason: 'fraction $f 存取往返漂移超过千分之一（stored=$stored）',
        );
      }
    });
  });

  group('mangaImageUrl', () {
    test('逐段 percent-encode，保留 / 结构（与拦截器 decodeComponent 对称）', () {
      expect(
        MangaMyComicPage.mangaImageUrl('p001.jpg'),
        'https://manga.local/img/p001.jpg',
      );
      expect(
        MangaMyComicPage.mangaImageUrl('vol 1/p 01.jpg'),
        'https://manga.local/img/vol%201/p%2001.jpg',
      );
      expect(
        MangaMyComicPage.mangaImageUrl('images/p001.jpg'),
        'https://manga.local/img/p001.jpg',
      );
      expect(
        MangaMyComicPage.mangaImageUrl(r'.\images\p001.jpg'),
        'https://manga.local/img/p001.jpg',
      );
      // 子目录结构保留（不被整体 encode 成 %2F）。
      expect(
        MangaMyComicPage.mangaImageUrl('a/b/c.png').contains('%2F'),
        isFalse,
      );
      expect(
        MangaMyComicPage.mangaImageUrl('vol 1/p 01.jpg', useCustomScheme: true),
        'mycomic-manga://manga.local/img/vol%201/p%2001.jpg',
      );
    });

    test('页会话代次进查询串：换章后同名页 URL 不同，拦截器解析不受影响', () {
      final String chapter1 = MangaMyComicPage.mangaImageUrl(
        'images/page-000001.png',
        version: 1,
      );
      final String chapter2 = MangaMyComicPage.mangaImageUrl(
        'images/page-000001.png',
        version: 2,
      );
      expect(chapter1, 'https://manga.local/img/page-000001.png?v=1');
      expect(chapter2, isNot(chapter1));
      expect(Uri.parse(chapter2).path, '/img/page-000001.png');
      expect(
        MangaMyComicPage.decodeMangaImagePath(
          Uri.parse(chapter2).path.substring('/img/'.length),
        ),
        'page-000001.png',
      );
    });

    test('卷作用域进查询串：两卷同名页、同代次的 URL 也不同', () {
      final String volume1Scope = MangaMyComicPage.mangaPageScope(
        '/data/my_comic_books/志乃と恋/images',
      );
      final String volume2Scope = MangaMyComicPage.mangaPageScope(
        '/data/my_comic_books/志乃と恋 2/images',
      );
      expect(volume1Scope, isNot(volume2Scope));
      expect(
        MangaMyComicPage.mangaPageScope('/data/my_comic_books/志乃と恋/images'),
        volume1Scope,
        reason: '同一卷恒得同一作用域，保住同卷内缓存复用',
      );
      final String volume1 = MangaMyComicPage.mangaImageUrl(
        'images/page_000000.jpg',
        version: 1,
        scope: volume1Scope,
      );
      final String volume2 = MangaMyComicPage.mangaImageUrl(
        'images/page_000000.jpg',
        version: 1,
        scope: volume2Scope,
      );
      expect(volume1, isNot(volume2));
      expect(
        volume1,
        'https://manga.local/img/page_000000.jpg?s=$volume1Scope&v=1',
      );
      expect(Uri.parse(volume1).path, '/img/page_000000.jpg');
    });
  });
}
