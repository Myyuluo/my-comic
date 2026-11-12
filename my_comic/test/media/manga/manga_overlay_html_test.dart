
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/media/manga/manga_overlay_html.dart';
import 'package:my_comic/src/media/manga/manga_reader_preferences.dart';
import 'package:my_comic/src/media/manga/manga_reading_mode.dart';
import 'package:my_comic/src/media/manga/manga_view_prefs.dart';
import 'package:my_comic_engine/media/manga/mokuro_payload.dart';

MokuroImage _pageWithTwoBlocks() {
  return const MokuroImage(
    url: 'p001.jpg',
    size: MokuroSize(1000, 2000),
    blocks: <MokuroBlock>[
      MokuroBlock(
        rectangle: MokuroRect.fromLTWH(100, 200, 300, 400),
        isVertical: true,
        fontSize: 32,
        zIndex: 0,
        lines: <String>['一行目', '二行目'],
      ),
      MokuroBlock(
        rectangle: MokuroRect.fromLTWH(500, 600, 200, 100),
        isVertical: false,
        fontSize: 24,
        zIndex: 1,
        lines: <String>['横書き'],
      ),
    ],
  );
}

void main() {
  group('mangaPageDivHtml', () {
    test('包 <div class="manga-page"> + <img pointer-events:none>', () {
      final String html =
          mangaPageDivHtml(_pageWithTwoBlocks(), 'manga.local/0/p001.jpg');
      expect(html.contains('<div class="manga-page"'), isTrue);
      expect(html.contains('src="manga.local/0/p001.jpg"'), isTrue);
      // 底图必须 pointer-events:none（点击交给页级手势机）。
      expect(
        RegExp(r'<img[^>]*pointer-events\s*:\s*none').hasMatch(html),
        isTrue,
        reason: '底图 <img> 必须 pointer-events:none',
      );
      expect(html.contains('ocr-box'), isFalse,
          reason: 'OCR 文本层已随 OCR 域移除');
    });

    // spread 页同时受槽宽与 100vh 限制，横屏/矮窗口都不得裁切。
    test('spread 单页同时受 100vw 与 100vh 宽高约束', () {
      final String html = mangaPageDivHtml(_pageWithTwoBlocks(), 'p.jpg',
          pagesInSpread: 1, isWebtoon: false);
      // 1000×2000：宽=min(100vw,50vh)，高=min(100vh,200vw)。
      expect(html.contains('width:min(100vw,50vh)'), isTrue);
      expect(html.contains('height:min(100vh,200vw)'), isTrue);
      expect(html.contains('aspect-ratio:'), isTrue,
          reason: '页容器必须与原图保持同一宽高比');
    });

    test('折叠屏铰链缝：双页每页让出半条缝，单页不受影响', () {
      final String html = mangaPageDivHtml(_pageWithTwoBlocks(), 'p.jpg',
          pagesInSpread: 2, isWebtoon: false, spreadGutterPx: 24);
      expect(html, contains('width:min(calc(50vw - 12px),50vh)'));
      expect(html, contains('height:min(100vh,calc((50vw - 12px) * 2))'));
      final String solo = mangaPageDivHtml(_pageWithTwoBlocks(), 'p.jpg',
          pagesInSpread: 1, isWebtoon: false, spreadGutterPx: 24);
      expect(solo, contains('width:min(100vw,50vh)'),
          reason: '宽页独占一屏没有「两页之间」');
    });

    test('折叠屏铰链缝：跨页容器两页之间留出整条缝', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        spreadGutterPx: 24,
      );
      expect(doc, contains('column-gap:24px;'));
      final String flat = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
      );
      expect(flat, isNot(contains('column-gap:')));
    });

    test('spread 双页每页最多 50vw 且高度不超过 100vh', () {
      final String html = mangaPageDivHtml(_pageWithTwoBlocks(), 'p.jpg',
          pagesInSpread: 2, isWebtoon: false);
      expect(html.contains('width:min(50vw,50vh)'), isTrue);
      expect(html.contains('height:min(100vh,100vw)'), isTrue);
    });

    test('webtoon → .manga-page div 不内联 width（宽由 style 块 width:100vw 给）', () {
      const MokuroImage blank = MokuroImage(
          url: 'p.jpg', size: MokuroSize(800, 1200), blocks: <MokuroBlock>[]);
      final String html =
          mangaPageDivHtml(blank, 'p.jpg', pagesInSpread: 1, isWebtoon: true);
      // .manga-page div 的 style 不含 vw 宽（webtoon 宽由外部 style 块给）。
      expect(html.contains('width:100vw'), isFalse,
          reason: 'webtoon 页 div 不应内联 width:100vw');
      expect(html.contains('width:50vw'), isFalse);
      expect(html.contains('aspect-ratio:'), isTrue);
      // webtoon 底图必须 lazy 加载（整书单文档，避免一次性解码全卷）。
      expect(html.contains('loading="lazy"'), isTrue,
          reason: 'webtoon <img> 必须 loading="lazy"');
    });
  });

  group('mangaWindowDocument', () {
    test('spread RTL → flex-row + direction:rtl，不注入选词脚本', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page],
        <String>['manga.local/0/p001.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
      );
      expect(doc.contains('<!DOCTYPE html>'), isTrue);
      expect(doc.contains('flex-direction:row'), isTrue);
      expect(doc.contains('direction:rtl'), isTrue);
      // 选词 / 查词脚本已随 OCR 域移除（ticket 05）。
      expect(doc.contains('window.myComicSelection'), isFalse);
      // 唯一一个 pointerup 监听
      expect('pointerup'.allMatches(doc).length, 1,
          reason: '全文档恰好一个 pointerup 监听（C1 收敛不变式）');
    });

    test('spread 视口裁剪 + translateX 翻页机（ERRATA C1）', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        pageSpreadIndices: <int>[0, 1],
        currentSpread: 1,
      );
      // 外层固定视口 overflow:hidden（只显示当前跨页）。
      expect(doc.contains('#manga-viewport{overflow:hidden'), isTrue,
          reason: 'spread 必须有 overflow:hidden 视口裁剪');
      expect(doc.contains('id="manga-viewport"'), isTrue);
      // strip 用 translateX 平移；翻页机 + 恢复定位函数存在。
      expect(doc.contains('__mangaApplyTranslate'), isTrue,
          reason: 'spread 必须有 translateX 定位函数');
      expect(doc.contains('translateX'), isTrue);
      // 翻页手势报 onMangaTurn。
      expect(doc.contains('onMangaTurn'), isTrue,
          reason: 'spread swipe 必须报 onMangaTurn');
      // 恢复定位用到 currentSpread=1。
      expect(RegExp(r'CURRENT\s*=\s*1').hasMatch(doc), isTrue,
          reason: '恢复定位必须用 currentSpread');
      // 每页带 data-spread 标注（供 JS 按跨页分组）。
      expect(doc.contains('data-spread="0"'), isTrue);
      expect(doc.contains('data-spread="1"'), isTrue);
    });

    test('裸图单击不打开大图，空白点回传 onTapEmpty', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page],
        <String>['p.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        pageSpreadIndices: <int>[0],
      );
      expect(doc.contains('onImageTap'), isFalse,
          reason: '裸图单击必须留在阅读器，不再打开独立大图');
      expect(doc.contains("b.callHandler('onTapEmpty');"), isTrue);
      expect(doc.contains('__mangaTapLookupAt'), isFalse,
          reason: '点击即识别已移除，不得再有回放钩子');
      expect(doc.contains('__mangaSetRescanMode'), isFalse,
          reason: '框选重识别已移除，不得再有 JS 侧模式门');
      expect(doc.contains('_selectOcrChar'), isFalse,
          reason: 'OCR 文本层与选词胶水已移除');
      // 收敛不变式：恰好一个 pointerup 监听。
      expect("addEventListener('pointerup'".allMatches(doc).length, 1,
          reason: '全文档恰好一个 pointerup 监听（C1 收敛不变式）');
      expect(doc.contains('__mangaReplaceOcr'), isFalse,
          reason: '后台 OCR 热替换已移除');
    });

    test('webtoon → 竖向堆叠（column）', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page],
        <String>['manga.local/0/p001.jpg'],
        mode: MangaReadingMode.webtoon,
        spreadDirection: 'rtl',
      );
      expect(doc.contains('flex-direction:column'), isTrue);
      // webtoon 滚动近边缘报 onMangaScroll（ERRATA C1）。
      expect(doc.contains('onMangaScroll'), isTrue,
          reason: 'webtoon 滚动必须报 onMangaScroll');
      // webtoon 不裁 spread 视口（靠文档竖滚）。
      expect(doc.contains('#manga-viewport{overflow:hidden'), isFalse,
          reason: 'webtoon 不应有 spread 视口裁剪');
      // webtoon 模式不报 spread 翻页。
      expect(doc.contains('onMangaTurn'), isTrue,
          reason: '手势机仍内联（IS_WEBTOON 闸门内部不触发翻页）');
    });

    test('spread 双页跨页：固定视口容器内完整居中', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        pageSpreadIndices: <int>[0, 0],
        pagesPerSpread: <int>[2, 2], // 同一双页跨页
      );
      expect('width:min(50vw,50vh)'.allMatches(doc).length, 2,
          reason: '双页各自受 50vw 与 100vh 双重约束');
      expect(doc.contains('#manga-viewport{overflow:hidden'), isTrue);
      expect(doc.contains('class="manga-spread" data-spread="0"'), isTrue);
      expect(
          doc.contains('width:100vw;height:100vh;align-items:center;'
              'justify-content:center'),
          isTrue,
          reason: '每个 spread 必须有独立的全视口居中槽');
    });

    test('spread 单页跨页：每页在独立 100vw 容器内 contain', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'ltr',
        pageSpreadIndices: <int>[0, 1],
        pagesPerSpread: <int>[1, 1], // 两个独立单页跨页
      );
      expect('width:min(100vw,50vh)'.allMatches(doc).length, 2);
      expect('class="manga-spread"'.allMatches(doc).length, 2,
          reason: '两个单页 spread 应各有一个固定视口容器');
    });

    // HIGH-1：webtoon scroll 报**页内** fraction（(scrollY-offsetTop)/offsetHeight），
    // 与 __mangaScrollToSpread 恢复口径统一；绝非文档全局 y/docH。
    test('webtoon scroll 报页内 fraction（HIGH-1），非文档全局', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.webtoon,
        spreadDirection: 'rtl',
      );
      // 页内归一化：(y - page.offsetTop) / page.offsetHeight。
      expect(doc.contains('pages[i].offsetTop'), isTrue,
          reason: 'fraction 必须按视口顶部所在页的 offsetTop 算页内偏移');
      expect(doc.contains('pages[i].offsetHeight'), isTrue,
          reason: 'fraction 分母必须是该页 offsetHeight（页内口径）');
      // 旧的文档全局口径（scrollHeight - vh 当分母）必须移除。
      expect(doc.contains('scrollHeight - vh'), isFalse,
          reason: 'webtoon fraction 不得再用文档全局口径（scrollHeight-vh）');
      // 恢复函数仍按页内 fraction 微调。
      expect(doc.contains('__mangaScrollToSpread'), isTrue);
      expect(doc.contains('page.offsetTop + (fraction'), isTrue,
          reason: '恢复定位必须 page.offsetTop + fraction*page.offsetHeight（同口径）');
    });

    // BUG-051：桌面鼠标三种自然操作（滚轮/拖动/键盘）在 spread 模式全失效。
    // ① spread 必须监听 wheel→onMangaTurn（overflow:hidden 视口下滚轮本是死操作，
    //    复用为桌面 swipe 等价物）；② webtoon 不接 wheel→翻页（保留原生竖滚）；
    // ③ 禁用 user-select/user-drag + dragstart preventDefault，消除拖动残影「秃瓢」。
    test('spread 接 wheel→onMangaTurn 且 IS_WEBTOON=false 闸门放行（BUG-051）', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        pageSpreadIndices: <int>[0, 1],
      );
      // wheel 监听内联存在，且被 `if (!IS_WEBTOON) {` 闸门包裹（闸门在监听注册之前）。
      final int wheelIdx = doc.indexOf("addEventListener('wheel'");
      final int spreadWheelIdx =
          doc.indexOf("addEventListener('wheel'", wheelIdx + 1);
      final int gateIdx = doc.lastIndexOf('if (!IS_WEBTOON) {', spreadWheelIdx);
      expect(gateIdx >= 0, isTrue, reason: 'wheel 必须有 if(!IS_WEBTOON) 闸门');
      expect(spreadWheelIdx > gateIdx, isTrue,
          reason: 'wheel 监听必须在 !IS_WEBTOON 闸门之内');
      // spread → IS_WEBTOON=false → 运行时闸门放行，滚轮翻页生效。
      expect(doc.contains('var IS_WEBTOON = false'), isTrue,
          reason: 'spread 必须 IS_WEBTOON=false（滚轮翻页生效）');
      // wheel 回调必须 preventDefault（overflow:hidden 视口下消除无操作反馈）并按
      // deltaY 符号报 next/prev。
      expect(doc.contains('e.preventDefault()'), isTrue);
      expect(doc.contains("dir > 0 ? 'next' : 'prev'"), isTrue,
          reason: 'wheel 必须按滚动方向报 next/prev');
      // 翻页触发按**累计位移**而非「一个事件 = 一页」：鼠标一格立即翻，触控板碎
      // delta 攒够才翻。旧实现首个事件就翻 + 320ms 全禁，滚轮上限约 3 页/秒。
      expect(doc.contains('_wheelAccum'), isTrue,
          reason: '滚轮翻页必须按累计 delta 触发，不能一个事件翻一页');
      expect(doc.contains('_wheelLock = false; }, 110)'), isTrue,
          reason: '滚轮合并窗口 110ms（旧 320ms 把翻页上限压到约 3 页/秒）');
    });

    test('webtoon IS_WEBTOON=true 运行时跳过 wheel→翻页（保留原生竖滚，BUG-051）', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.webtoon,
        spreadDirection: 'rtl',
      );
      // wheel 源码内联（与 onMangaTurn 同样常驻），但 IS_WEBTOON=true 让
      // if(!IS_WEBTOON) 闸门在运行时跳过滚轮翻页 → 不抢 WebView 原生竖滚。
      expect(doc.contains('var IS_WEBTOON = true'), isTrue,
          reason: 'webtoon 必须 IS_WEBTOON=true（运行时跳过滚轮翻页闸门）');
    });

    test('spread + webtoon 都禁用原生选区/拖拽残影「秃瓢」（BUG-051）', () {
      final MokuroImage page = _pageWithTwoBlocks();
      for (final MangaReadingMode mode in <MangaReadingMode>[
        MangaReadingMode.spread,
        MangaReadingMode.webtoon,
      ]) {
        final String doc = mangaWindowDocument(
          <MokuroImage>[page],
          <String>['a.jpg'],
          mode: mode,
          spreadDirection: 'rtl',
        );
        // 文字选区禁用（查词走坐标式 DOM 读取，不依赖原生选区，故安全）。
        expect(doc.contains('user-select:none'), isTrue,
            reason: '$mode：必须禁用原生文字选区');
        // 图片拖拽禁用 + dragstart 兜底 preventDefault。
        expect(doc.contains('user-drag:none'), isTrue,
            reason: '$mode：必须禁用原生图片拖拽');
        expect(
            RegExp(r"addEventListener\(\s*'dragstart'").hasMatch(doc), isTrue,
            reason: '$mode：必须 preventDefault dragstart 兜底消除残影');
      }
    });

    test('spread RTL 只反转组内页序，根 strip 保持 LTR 稳定几何', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String docRtl = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
      );
      // 同一个 spread 内部的两页 DOM 顺序不变（左右由 CSS direction 翻）；根 strip
      // 保持 LTR，让 offsetLeft 恒为 100vw 的整数倍。跨 spread 的排列顺序另见
      // 「spread RTL 的 strip 几何倒序」。
      expect(docRtl.indexOf('a.jpg') < docRtl.indexOf('b.jpg'), isTrue);
      expect(
          docRtl.contains('#manga-root{display:flex;flex-direction:row;'
              'direction:ltr;'),
          isTrue);
      expect(docRtl.contains('justify-content:center;direction:rtl'), isTrue);

      final String docLtr = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'ltr',
      );
      expect(docLtr.contains('justify-content:center;direction:ltr'), isTrue);
      expect(docLtr.contains('direction:rtl'), isFalse);
    });

    test('spread RTL 的 strip 几何倒序：下一跨页在左，翻页动画方向才对', () {
      final MokuroImage page = _pageWithTwoBlocks();
      List<int> spreadOrderOf(String doc) {
        // 只取 spread 容器：每页的 .manga-page 也带 data-spread，混进来会得到
        // [2,2,1,1,0,0] 这种成对序列。
        final RegExp re = RegExp(r'class="manga-spread" data-spread="(\d+)"');
        return re
            .allMatches(doc)
            .map((RegExpMatch m) => int.parse(m.group(1)!))
            .toList();
      }

      final String docRtl = mangaWindowDocument(
        <MokuroImage>[page, page, page],
        <String>['a.jpg', 'b.jpg', 'c.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        pageSpreadIndices: const <int>[0, 1, 2],
      );
      // RTL：spread 2 排在最左（offsetLeft 最小），所以「前进」= 画面向右滑、新页
      // 从左边进——与 tap zone / 方向键早已按 RTL 镜像的输入语义一致。
      // 修复前这里是 [0, 1, 2]：输入镜像了、视觉没镜像，按前进键画面往后退的方向滑。
      expect(spreadOrderOf(docRtl), <int>[2, 1, 0]);

      final String docLtr = mangaWindowDocument(
        <MokuroImage>[page, page, page],
        <String>['a.jpg', 'b.jpg', 'c.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'ltr',
        pageSpreadIndices: const <int>[0, 1, 2],
      );
      expect(spreadOrderOf(docLtr), <int>[0, 1, 2]);

      // 两个方向都必须保持根 strip 的 LTR 几何：offsetLeft 得是稳定的 100vw 整数倍，
      // 否则 __mangaApplyTranslate 的 -offsetLeft 口径失效（这正是当初钉死 LTR 的原因）。
      for (final String doc in <String>[docRtl, docLtr]) {
        expect(
            doc.contains('#manga-root{display:flex;flex-direction:row;'
                'direction:ltr;'),
            isTrue);
      }
    });

    test('swipe 方向随 RTL 镜像，与 strip 几何同源', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page],
        <String>['a.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
      );
      // 拖动内容向左露出的是 strip 右边那一跨页；RTL 倒序后右边是 prev，所以判据
      // 必须含 IS_RTL。修复前是写死的 `dx < 0 ? 'next' : 'prev'`。
      expect(doc.contains("(swipeRight === IS_RTL) ? 'next' : 'prev'"), isTrue,
          reason: 'swipe 必须按 IS_RTL 镜像，否则与倒序后的 strip 几何相反');
      expect(doc.contains("dx < 0 ? 'next' : 'prev'"), isFalse,
          reason: '不许再有不看阅读方向的写死 swipe 判据');
    });

    test('键盘平移导出 __mangaPanBy，且平移被钳制在视口内', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page],
        <String>['a.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
      );
      // 视口比例入参 + 「视野怎么动」的符号（故 _panBy 取负）。
      expect(doc.contains('window.__mangaPanBy = function(fx, fy){'), isTrue,
          reason: '方向键平移要走导出的 JS 入口，而不是在 JS 里自己监听键盘');
      expect(
          doc.contains(
              '_panBy(-window.innerWidth * fx, -window.innerHeight * fy);'),
          isTrue);
      // 钳制：PAN_X ∈ [vw*(1-ZOOM), 0]，spread 的 PAN_Y 同理。此前完全没有边界，
      // 拖动/方向键能把页面推出视口且回不来。
      expect(doc.contains('function _clampPan(){'), isTrue);
      expect(
          doc.contains('var minX = window.innerWidth * (1 - ZOOM);'), isTrue);
      expect(doc.contains('if (canvasMoved) { _clampPan(); _applyCanvas(); }'),
          isTrue,
          reason: '拖动/惯性/方向键三条平移路径必须共用同一条钳制规则');
      // ZOOM<=1 时位置归 _recenterPan 居中，钳制必须让路，否则缩小后页面被顶到左边。
      expect(doc.contains('if (ZOOM <= 1) return;'), isTrue);
    });

    test('online image load replaces bootstrap dimensions with natural size',
        () {
      final String doc = mangaWindowDocument(
        <MokuroImage>[
          const MokuroImage(
            url: 'online.jpg',
            size: MokuroSize(1000, 1400),
            blocks: <MokuroBlock>[],
          ),
        ],
        <String>['online.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
      );

      expect(doc.contains('window.__mangaUpdatePageGeometry'), isTrue);
      expect(doc.contains('image.naturalWidth'), isTrue);
      expect(doc.contains('image.naturalHeight'), isTrue);
      expect(doc.contains("page.style.aspectRatio = width + ' / ' + height"),
          isTrue);
      expect(doc.contains('_inspectSource(page);'), isTrue);
      expect(doc.contains('var fit = Math.min(sx, sy);'), isTrue);
    });

    test('desktop zoom and right-button drag/menu contract is embedded', () {
      final String doc = mangaWindowDocument(
        <MokuroImage>[_pageWithTwoBlocks()],
        <String>['p.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        zoomPercent: 100,
      );
      // 缩放边界由参数注入（默认 50%..400%），不再是写死的 0.5/2。
      expect(doc.contains('var ZOOM_MIN = 0.5;'), isTrue);
      expect(doc.contains('var ZOOM_MAX = 4.0;'), isTrue);
      expect(doc.contains('rightDrag.startX) > 4'), isTrue);
      expect(doc.contains("callHandler('onMangaContextMenu'"), isTrue);
      expect(doc.contains("callHandler('onMangaZoomChanged'"), isTrue);
      expect(doc.contains('e.ctrlKey || e.metaKey'), isTrue);
      // 滚轮缩放必须是**对齐到 ZOOM_STEP 网格的定量步进**，与右键菜单的 ±10 个
      // 百分点同口径。曾经用过按 delta 幅值的乘法 `Math.exp(steps * 0.2 * ZOOM_SENS)`，
      // 那让「一格缩多少」取决于本机 deltaY 的绝对值（WebView2 高 DPI 上一格不是
      // 100，BUG-1065 实测 67），用户实测一格约 112%、既非设计值也无法预期。
      expect(
          doc.contains(
              'var ZOOM_STEP = Math.max(1, Math.round(10 * ZOOM_SENS));'),
          isTrue,
          reason: '滚轮步长必须是 10 个百分点（乘灵敏度）的定量网格，不能是乘法缩放');
      // 鼠标一格（>=40）的网格步进不能退回按幅值乘法缩放；指数只允许出现在
      // 精密手势分支（BUG-2758），并且以 -dy/100 还原 fork 合成的捏合比例。
      expect('Math.exp('.allMatches(doc).length, 1,
          reason: '乘法指数缩放只属于精密手势分支，鼠标一格仍走网格');
      final int precise = doc.indexOf('if (Math.abs(dy) < PRECISE_ZOOM_DELTA) {');
      expect(precise, greaterThan(0));
      expect(
          doc
              .substring(precise, precise + 160)
              .contains('_zoomAbout(ZOOM * Math.exp(-dy / 100 * ZOOM_SENS), '
                  'e.clientX, e.clientY);'),
          isTrue,
          reason: '触控板捏合（-100·ln 比例的碎 delta）必须连续跟手，'
              '攒够 40 才走 10% 要张开约 1.5 倍');
      expect(doc.contains('var PRECISE_ZOOM_DELTA = 40;'), isTrue,
          reason: '鼠标一格恒 >=40，精密增量恒 <40');
      expect(
          doc.contains('(Math.floor(cur / ZOOM_STEP) + 1) * ZOOM_STEP'), isTrue,
          reason: '放大必须对齐到网格，否则捏合留下的非整值会一路歪下去');
      expect(
          doc.contains('(Math.ceil(cur / ZOOM_STEP) - 1) * ZOOM_STEP'), isTrue,
          reason: '缩小必须对齐到网格');
      expect(doc.contains('var cur = Math.round(ZOOM * 1000) / 10;'), isTrue,
          reason: '必须先消掉浮点毛刺，否则 1.2000000000000002 缩小一步会原地不动');
      expect(doc.contains('e.deltaMode === 1'), isTrue,
          reason: 'deltaMode 必须归一化，否则行/页模式步长完全不同');
    });

    test('缩放范围与灵敏度随参数注入，触屏有捏合缩放', () {
      final String doc = mangaWindowDocument(
        <MokuroImage>[_pageWithTwoBlocks()],
        <String>['p.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        zoomPercent: 100,
        zoomMaxPercent: 300,
        zoomSensitivity: 200,
      );
      expect(doc.contains('var ZOOM_MAX = 3.0;'), isTrue);
      expect(doc.contains('var ZOOM_SENS = 2.0;'), isTrue);
      // 触屏此前完全无法缩放：viewport 是 user-scalable=no（必须，否则浏览器原生
      // 缩放与 #manga-canvas 的 transform 打架），而 JS 侧没有任何多指处理。
      expect(doc.contains("e.pointerType === 'touch'"), isTrue,
          reason: '必须自己处理触点，浏览器原生缩放被 user-scalable=no 禁掉了');
      expect(doc.contains('_pinchGeom'), isTrue, reason: '必须有双指捏合几何');
      expect(doc.contains('Math.pow(g.dist / pinch.dist, ZOOM_SENS)'), isTrue,
          reason: '灵敏度设置声明覆盖滚轮与捏合，pinch 比率也必须应用 ZOOM_SENS');
      expect(doc.contains("addEventListener('pointermove'"), isTrue,
          reason: '捏合需要 pointermove 才能跟手');
    });

    test('点击边缘翻页可关，且方向随 RTL 镜像', () {
      String docFor({required bool tapZonePaging, required String direction}) =>
          mangaWindowDocument(
            <MokuroImage>[_pageWithTwoBlocks()],
            <String>['p.jpg'],
            mode: MangaReadingMode.spread,
            spreadDirection: direction,
            tapZonePaging: tapZonePaging,
          );
      final String on = docFor(tapZonePaging: true, direction: 'rtl');
      expect(on.contains('var TAP_ZONE_PAGING = true;'), isTrue);
      expect(on.contains('var IS_RTL = true;'), isTrue);
      // RTL 下左边缘前进（LTR 相反）。镜像已从 JS 的 `IS_RTL ? ...` 三元挪到
      // Dart 的 mangaTapZones()，注入的热区表里 forward 就是最终值——JS 不得再
      // 镜像一次（会抵消）。表本身的几何见 manga_tap_zones_test.dart。
      expect(on.contains('[0,0,0.25,1,true]'), isTrue,
          reason: 'RTL 左竖条必须已经是前进');
      final String ltrOn = docFor(tapZonePaging: true, direction: 'ltr');
      expect(ltrOn.contains('[0,0,0.25,1,false]'), isTrue,
          reason: 'LTR 左竖条必须是后退');
      expect(on.contains("IS_RTL ? 'next' : 'prev'"), isFalse,
          reason: 'JS 侧不得二次镜像');
      final String off = docFor(tapZonePaging: false, direction: 'ltr');
      expect(off.contains('var TAP_ZONE_PAGING = false;'), isTrue);
      expect(off.contains('var IS_RTL = false;'), isTrue);
    });

    test('翻页动画偏好决定 #manga-root 过渡声明', () {
      String docFor(MangaPageAnimation animation) => mangaWindowDocument(
            <MokuroImage>[_pageWithTwoBlocks()],
            <String>['p.jpg'],
            mode: MangaReadingMode.spread,
            spreadDirection: 'rtl',
            pageAnimation: animation,
          );
      // 默认速度 normal（MyComicMotion token），缓动统一 cubic-bezier(.2,.7,.2,1)。
      final int normalMs = PageTurnAnimationSpeed.normal.durationMs;
      expect(
          docFor(MangaPageAnimation.slide).contains(
              'transition:transform ${normalMs}ms cubic-bezier(.2,.7,.2,1);'),
          isTrue);
      // none = 完全不声明过渡（要极限响应的用户）。
      final String none = docFor(MangaPageAnimation.none);
      expect(none.contains('transition:transform '), isFalse);
      expect(none.contains('transition:opacity '), isFalse);
      // fade 只过渡 opacity（淡出 / 淡入各半程），位移在淡出后瞬时完成。
      final String fade = docFor(MangaPageAnimation.fade);
      expect(fade.contains('transition:opacity ${(normalMs / 2).round()}ms '),
          isTrue);
      expect(fade.contains('transition:transform '), isFalse);
      expect(fade.contains("if (PAGE_ANIM === 'fade') { _fadeTurn(ms); return; }"),
          isTrue);
      // cover：strip 本身瞬时定位（root 不声明过渡），动的是克隆覆盖层。
      final String cover = docFor(MangaPageAnimation.cover);
      expect(cover.contains("var PAGE_ANIM = 'cover';"), isTrue);
      expect(cover.contains('transition:transform '), isFalse);
      expect(cover.contains('transition:opacity '), isFalse);
      expect(cover.contains('.manga-cover-layer{position:absolute;'), isTrue);
      expect(cover.contains('function _coverBegin(from, to){'), isTrue);
    });

    test('翻页动画速度三档注入 PAGE_ANIM_MS 与过渡时长', () {
      String docFor(PageTurnAnimationSpeed speed) => mangaWindowDocument(
            <MokuroImage>[_pageWithTwoBlocks()],
            <String>['p.jpg'],
            mode: MangaReadingMode.spread,
            spreadDirection: 'rtl',
            pageAnimationSpeed: speed,
          );
      for (final PageTurnAnimationSpeed speed in PageTurnAnimationSpeed.values) {
        final String doc = docFor(speed);
        expect(doc.contains('var PAGE_ANIM_MS = ${speed.durationMs};'), isTrue,
            reason: '$speed');
        expect(
            doc.contains('transition:transform ${speed.durationMs}ms '
                'cubic-bezier(.2,.7,.2,1);'),
            isTrue,
            reason: '$speed');
      }
      // 不再写死 180 / 160ms。
      expect(docFor(PageTurnAnimationSpeed.normal).contains('180ms'), isFalse);
    });

    test('拖动跟手开关、阈值与长距离跳页上限注入 JS', () {
      String docFor({bool followDrag = true}) => mangaWindowDocument(
            <MokuroImage>[_pageWithTwoBlocks()],
            <String>['p.jpg'],
            mode: MangaReadingMode.spread,
            spreadDirection: 'rtl',
            followDrag: followDrag,
          );
      final String on = docFor();
      expect(on.contains('var FOLLOW_DRAG = true;'), isTrue);
      expect(docFor(followDrag: false).contains('var FOLLOW_DRAG = false;'),
          isTrue);
      expect(on.contains('var FOLLOW_COMMIT = 0.25;'), isTrue);
      expect(on.contains('var FOLLOW_FLING = 0.6;'), isTrue);
      expect(on.contains('var MAX_ANIM_DIST = 1;'), isTrue);
      // 跟手只对有位移的效果生效，阈值分支按是否真跟了手选择。
      expect(
          on.contains("(PAGE_ANIM === 'slide' || PAGE_ANIM === 'cover')"),
          isTrue);
      expect(on.contains('commit = aux > FOLLOW_COMMIT * (window.innerWidth || 1)'),
          isTrue);
      // 运行中换设置的入口（设置面板 / 系统减弱动态效果）与独立的过渡样式表。
      expect(on.contains('window.__mangaSetPageAnimation = function'), isTrue);
      expect(on.contains('<style id="manga-anim-css">#manga-root{'), isTrue);
    });

    test('墨水屏强制无动画；animateTransitions 不再参与判定', () {
      String docFor(MangaReaderPreferences prefs) => mangaWindowDocument(
            <MokuroImage>[_pageWithTwoBlocks()],
            <String>['p.jpg'],
            mode: MangaReadingMode.spread,
            spreadDirection: 'rtl',
            pageAnimation: MangaPageAnimation.cover,
            readerPreferences: prefs,
          );
      expect(
          docFor(const MangaReaderPreferences(einkMode: true))
              .contains("var PAGE_ANIM = 'none';"),
          isTrue);
      expect(
          docFor(const MangaReaderPreferences(animateTransitions: false))
              .contains("var PAGE_ANIM = 'cover';"),
          isTrue,
          reason: '翻页动画只认 manga_page_animation，旧开关只是它的投影');
    });

    test('纵向分页相邻翻页平滑滚动，条漫不动', () {
      String docFor(MangaReadingMode mode) => mangaWindowDocument(
            <MokuroImage>[_pageWithTwoBlocks()],
            <String>['p.jpg'],
            mode: mode,
            spreadDirection: 'rtl',
          );
      final String paged = docFor(MangaReadingMode.pagedVertical);
      expect(paged.contains('var IS_VERTICAL_PAGED = true;'), isTrue);
      expect(paged.contains('Math.abs(target - from) === 1'), isTrue);
      expect(paged.contains('_animateScrollTo(top, ms);'), isTrue);
      expect(docFor(MangaReadingMode.webtoon).contains(
              'var IS_VERTICAL_PAGED = false;'),
          isTrue);
      // 条漫 / 纵向分页没有 strip，不出过渡样式表。
      expect(paged.contains('id="manga-anim-css"'), isFalse);
    });

    test('window document exposes its navigation generation', () {
      final String doc = mangaWindowDocument(
        <MokuroImage>[_pageWithTwoBlocks()],
        <String>['p.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        currentSpread: 7,
        documentGeneration: 42,
      );
      expect(doc.contains('window.__mangaDocumentGeneration=42;'), isTrue);
      expect(doc.contains('var CURRENT = 7;'), isTrue);
    });

    test('稳定图片 strip 全部页常驻，翻页不重建 WebView 文档', () {
      final String doc = mangaWindowDocument(
        <MokuroImage>[_pageWithTwoBlocks(), _pageWithTwoBlocks()],
        <String>['p0.jpg', 'p1.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'ltr',
        pageSpreadIndices: const <int>[0, 1],
        pagesPerSpread: const <int>[1, 1],
        pageNumbers: const <int>[0, 1],
      );
      expect('class="manga-page"'.allMatches(doc).length, 2,
          reason: '图片页全部常驻，翻页不应重建 WebView 文档');
      expect(
          doc.contains('data-page="0" data-pw="1000" data-ph="2000"'),
          isTrue);
      expect(
          doc.contains('data-page="1" data-pw="1000" data-ph="2000"'),
          isTrue);
      expect(doc.contains('data-ocr-loaded'), isFalse,
          reason: 'OCR 命中层已移除');
    });

    // BUG-1701：手机端「放大缩小跟上下滑动混了」的根因有两条，这一组把两个不变式
    // 钉死。① 手势所有权：touch-action 默认 auto 时浏览器在第一个 touchstart 就锁定
    // 原生 pan，pointermove 的 preventDefault 按 Pointer Events 规范并不阻止滚动，
    // 于是捏合与竖向滚动同时发生、滚动接管后还会取消指针序列把捏合状态清掉。
    // ② 纵向所有权：webtoon 是竖滚文档，纵向位置只能由 window.scrollY 表达；此前
    // PAN_Y 也参与，一次缩放同时产生 transform 位移和滚动位移。
    group('BUG-1701 触屏缩放与竖向滚动的所有权', () {
      String docFor(MangaReadingMode mode, {int zoomPercent = 100}) =>
          mangaWindowDocument(
            <MokuroImage>[_pageWithTwoBlocks()],
            <String>['p.jpg'],
            mode: mode,
            spreadDirection: 'ltr',
            zoomPercent: zoomPercent,
          );

      test('touch-action 恒为 none，不再有运行期切换的特例', () {
        for (final MangaReadingMode mode in MangaReadingMode.values) {
          final String doc = docFor(mode);
          expect(doc.contains('touch-action:none;'), isTrue,
              reason: '$mode：手势必须在第一个 touchstart 前就归 JS 独占，'
                  '否则捏合会被原生二指 pan 抢走');
          expect(doc.contains('document.body.style.touchAction'), isFalse,
              reason: '$mode：运行期切换 touch-action 对已开始的手势无效，'
                  '这个特例必须保持消除');
        }
      });

      test('webtoon 纵向位置只由 scrollY 拥有，PAN_Y 恒 0', () {
        final String doc = docFor(MangaReadingMode.webtoon);
        expect(
            doc.contains(
                'PAN_Y = IS_WEBTOON ? 0 : window.innerHeight * (1 - ZOOM) / 2;'),
            isTrue,
            reason: 'webtoon 竖滚文档不得再用 spread 的 PAN_Y 居中公式');
        expect(doc.contains('PAN_Y = IS_WEBTOON ? 0 : ay - localY * ZOOM;'),
            isTrue,
            reason: '缩放锚点补偿在 webtoon 必须写 scrollY 而非 PAN_Y');
        // 位置断言前先确认锚点唯一，避免同形 token 抢走 indexOf 的窗口。
        expect('var IS_WEBTOON = '.allMatches(doc).length, 1,
            reason: 'IS_WEBTOON 只允许一处声明');
        expect(
            doc.indexOf('var IS_WEBTOON = ') <
                doc.indexOf('function _recenterPan()'),
            isTrue,
            reason: '_recenterPan/_applyCanvas 在文档解析期就跑，'
                'IS_WEBTOON 必须先就绪，否则首帧按 spread 公式算 PAN_Y');
      });

      test('webtoon 缩放态下滚动坐标两端都换算 ZOOM', () {
        final String doc = docFor(MangaReadingMode.webtoon);
        expect(
            doc.contains('var top = (page.offsetTop + (fraction || 0) * '
                'page.offsetHeight) * ZOOM;'),
            isTrue,
            reason: 'offsetTop 是布局坐标，scrollTo 收视觉坐标，缺 *ZOOM 会定位错页');
        expect(doc.contains('var y = window.scrollY / ZOOM;'), isTrue,
            reason: 'onMangaScroll 的 fraction 与 offsetTop 同口径，'
                'scrollY 必须换回布局坐标');
        expect(
            doc.contains(
                'var localY = (IS_WEBTOON ? window.scrollY + ay : ay - PAN_Y) '
                '/ ZOOM;'),
            isTrue,
            reason: 'webtoon 的锚点屏幕坐标是 layout*ZOOM - scrollY');
        expect(
            doc.contains(
                'window.scrollTo(0, Math.max(0, localY * ZOOM - ay));'),
            isTrue,
            reason: '捏合后必须把锚点补偿写回 scrollY，否则画面跟着缩放跳走');
      });

      test('原生滚动关掉后 webtoon 竖滚由 JS 自己实现，带惯性', () {
        final String doc = docFor(MangaReadingMode.webtoon);
        expect(doc.contains('window.scrollBy(0, -dy);'), isTrue,
            reason: 'touch-action:none 后单指拖动必须自己驱动竖滚');
        expect(doc.contains('flickVy *= Math.pow(0.002, dt / 1000);'), isTrue,
            reason: '自实现滚动必须补上惯性，否则手感比原生退化');
        expect(doc.contains('if (drag && drag.touch) _startFlick(drag.vy);'),
            isTrue,
            reason: '惯性只给触屏：鼠标松手不该继续滑');
      });

      test('放大态的拖动先平移，只有贴边没吃掉的余量才判翻页（BUG-2875）', () {
        final String doc = docFor(MangaReadingMode.spread, zoomPercent: 150);
        expect(doc.contains('var ux = dx - (PAN_X - spx), aux = Math.abs(ux);'),
            isTrue,
            reason: 'ZOOM>1 时拖动已被 _panBy 消费为平移，只有余量才能判 swipe；'
                '行为见 manga_zoomed_swipe_edge_js_test');
        expect(doc.contains('ZOOM <= 1 &&'), isFalse,
            reason: '硬性 ZOOM<=1 门让 101%~105% 的捏合残留永远划不动');
        expect(doc.contains('function _panBy(dx, dy)'), isTrue,
            reason: '放大后必须能平移查看页面各处');
      });
    });
  });
}
