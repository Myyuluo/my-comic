import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi_core/fushi_core.dart';

/// 漫画阅读的接线守卫（源码扫描 + 键不变量）。
///
/// 漫画作为「第三种书」复用 EpubBooks/书架/进度/删除管线，正确性依赖数处接线不能被
/// 后续重构悄悄改断——一旦断掉，漫画行会带 EPUB 源标识被打开、进 EPUB 阅读器的解压/
/// 解析路径 → 崩溃或白屏。MangaFushiPage 过重无法在纯 widget test 拉起完整链路
/// （WebView + 词典引擎），故守卫落在最强可落地的源码语料层。
void main() {
  String read(String relativePath) {
    final File file = File(relativePath);
    expect(file.existsSync(), isTrue, reason: '守卫目标文件应存在：$relativePath');
    return file.readAsStringSync();
  }

  test('MangaFushiSource.kUniqueKey 是独立键 reader_manga，与 EPUB 源互异', () {
    expect(MangaFushiSource.kUniqueKey, 'reader_manga');
    expect(MangaFushiSource.instance.uniqueKey, 'reader_manga');
    expect(
      MangaFushiSource.instance.uniqueKey,
      isNot(ReaderFushiSource.instance.uniqueKey),
    );
  });

  test('书架列书按 format 路由：format==manga 的行带 MangaFushiSource 源标识', () {
    // BUG-1316：路由派生已收敛成公开的具名函数，故判据从「源码里有那串三元」升级
    // 成**直接调它**——行为断言比语料锚点强，也不会被等价改写绕过。
    expect(
      ReaderFushiSource.mediaSourceKeyFor(BookFormat.manga),
      MangaFushiSource.kUniqueKey,
      reason: '漫画行 mediaSourceIdentifier 应取 MangaFushiSource.kUniqueKey',
    );
    // PDF 阅读器已移除（ticket 05）：旧 PDF 行回退到书源，不能抢漫画的路由。
    expect(
      ReaderFushiSource.mediaSourceKeyFor(BookFormat.pdf),
      ReaderFushiSource.instance.uniqueKey,
    );
    expect(
      ReaderFushiSource.mediaSourceKeyFor(BookFormat.epub),
      ReaderFushiSource.instance.uniqueKey,
    );
  });

  test('_bookToMediaItem 走共享派生点，不得再内联自己的一套三元', () {
    final String src = read('lib/src/media/sources/reader_fushi_source.dart');
    expect(
      src.contains('mediaSourceIdentifier: mediaSourceKeyFor(format)'),
      isTrue,
      reason:
          '书架列书必须与「跳回原文」入口共用 mediaSourceKeyFor：'
          '两条各写各的，漫画/PDF 就会在其中一条上永远用错阅读器',
    );
  });

  test('AppModel 注册 MangaFushiSource.instance（否则打开漫画崩于 map 空断言）', () {
    final String src = read('lib/src/models/app_model.dart');
    expect(
      src.contains('MangaFushiSource.instance'),
      isTrue,
      reason:
          'populateMediaSources 必须注册 MangaFushiSource，'
          'item.getMediaSource 才能解析到它',
    );
  });

  test('media.dart 导出 manga_fushi_source（书架/路由处可见）', () {
    final String src = read('lib/media.dart');
    expect(src.contains('manga_fushi_source.dart'), isTrue);
  });

  // ── 身份：fushi://book/<bookKey>，无 manga:// 特例 ──────────────────

  test('漫画身份统一 fushi://book/<bookKey>，源与页面都不引入 manga:// 标识', () {
    final String source = read('lib/src/media/sources/manga_fushi_source.dart');
    final String page = read(
      'lib/src/media/manga/reader/manga_fushi_page.dart',
    );
    // 打开时从 fushi://book/ 标识解析 bookKey（与 PDF 完全同构），关书自动同步
    // （triggerAutoSyncAfterClose 的 fushi://book/ 前缀识别）天然工作。
    expect(
      source.contains('ReaderFushiSource.parseBookKey'),
      isTrue,
      reason: 'buildLaunchPage 必须用共享的 fushi://book/ 解析器',
    );
    expect(source.contains('manga://'), isFalse, reason: '不再有 manga:// 身份特例');
    expect(page.contains('manga://'), isFalse, reason: '页面也不得引入 manga:// 身份');
  });

  // ── 进度：ReaderPositions 页码口径 ──────────────────────────────────

  test('页码进度落 ReaderPositions.sectionIndex，且显式传 charOffset', () {
    final String src = read('lib/src/media/manga/reader/manga_fushi_page.dart');
    expect(src.contains('ReaderPositionRepository('), isTrue);
    expect(
      src.contains('sectionIndex: page'),
      isTrue,
      reason: '漫画用 sectionIndex 存 0-based 页码',
    );
    // charOffset 传 null 会掉进 EPUB 专用的「跨 section 精确锚失效」启发式；
    // spread 传 0，webtoon 存页内滚动千分比。
    expect(
      src.contains('charOffset: isWebtoon'),
      isTrue,
      reason: '必须显式传 charOffset（spread 0 / webtoon 千分比），不能传 null',
    );
    expect(src.contains('webtoonFractionToCharOffset'), isTrue);
    expect(
      src.contains('markEpubBookCompletedIfUnset'),
      isTrue,
      reason: '翻到末页写已读完',
    );
  });

  test('书架漫画进度按页计（与 PDF 共用 1-based 页序分支）', () {
    final String src = read('lib/src/media/sources/reader_fushi_source.dart');
    expect(
      src.contains('(pos.sectionIndex + 1)'),
      isTrue,
      reason: '页码型书进度用 1-based 页序，停在第 1 页也要计入在读',
    );
    expect(
      src.contains('position: pos == null'),
      isTrue,
      reason: '没有阅读记录的卷 position 必须是 0（未读），不能算停在第 1 页',
    );
    expect(src.contains('pageBased'), isTrue, reason: 'PDF/漫画共用页码型进度分支');
  });

  test('漫画阅读统计：字数走 OCR 记账、页数走独立列，两个量纲不交叉', () {
    final String src = read('lib/src/media/manga/reader/manga_fushi_page.dart');
    // ticket 05：阅读统计的写入（StudyClock / 字数页数记账）已移除；阅读进度
    // （reader_positions）仍是唯一落库的阅读状态，这里守它不再回潮。
    expect(src.contains('StudyClock'), isFalse,
        reason: '阅读统计写入已移除，不得再建计时时钟');
    expect(src.contains('mangaStatsForPages('), isFalse,
        reason: '漫画字数/页数统计聚合已移除');
  });

  // ── 阅读模式覆盖 ────────────────────────────────────────────────────

  test('阅读模式读写 EpubBooks.mangaReadingMode（null=自动判定）', () {
    final String src = read('lib/src/media/manga/reader/manga_fushi_page.dart');
    expect(src.contains('mangaReadingMode'), isTrue, reason: '打开时读列值、切换时写列值');
    expect(
      src.contains('detectReadingMode'),
      isTrue,
      reason: 'null 覆盖必须回落自动判定',
    );
  });

  // ── 阅读器只保留漫画阅读控件（ADR-0002）─────────────────────────────

  test('漫画页不再挂查词弹窗 / 选词 / Anki 制卡入口', () {
    final String src = read('lib/src/media/manga/reader/manga_fushi_page.dart');
    expect(
      src.contains('class MangaFushiPage extends BaseSourcePage'),
      isTrue,
      reason: '漫画页仍需 BaseSourcePage 提供阅读页生命周期与进度落库',
    );
    for (final String removed in <String>[
      'buildDictionary()',
      'searchDictionaryResult(',
      'setCurrentSentence(',
      'onMineFromPopup',
      'AnkiMiningContext(',
      'mineEntry(',
      '_registerSelectionHandlers',
    ]) {
      expect(src.contains(removed), isFalse, reason: '不得再出现 $removed');
    }
  });

  test('漫画页不再启用 OCR 控件或自动识别', () {
    final String src = read('lib/src/media/manga/reader/manga_fushi_page.dart');
    for (final String removed in <String>[
      'manga_ocr_boxes_toggle',
      '_toggleOcrBoxes',
      '_maybeStartVolumeOcr',
      '_maybeStartStreamingOcr',
      '_buildOcrProgressBadge',
      '_showManualVolumeOcrAction',
      '_showRerunVolumeOcrAction',
    ]) {
      expect(src.contains(removed), isFalse, reason: '不得再出现 $removed');
    }
  });
}
