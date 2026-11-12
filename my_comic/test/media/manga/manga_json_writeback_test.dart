/// manga.json 写侧：字号估算 + 并发写串行化 + 原子落盘 + 锁覆盖守卫。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:my_comic/src/media/manga/manga_json_writeback.dart';
import 'package:my_comic_engine/media/manga/mokuro_payload.dart';

String _mangaJson() {
  return jsonEncode(<String, Object?>{
    'ocr': <String, Object?>{
      'engine': 'local_onnx',
      'engine_signature': 'sig-abc',
      'schema_version': 2,
    },
    'pages': <Map<String, Object?>>[
      <String, Object?>{
        'url': 'p001.jpg',
        'width': 1000,
        'height': 1600,
        'blocks': <Object?>[],
      },
      <String, Object?>{
        'url': 'sub/p002.jpg',
        'width': 900,
        'height': 1200,
        'blocks': <Object?>[
          <String, Object?>{
            'box': <double>[10, 20, 110, 220],
            'vertical': true,
            'font_size': 24,
            'z_index': 0,
            'lines': <String>['既存ブロック'],
            'lines_coords': <Object?>[
              <Object?>[
                <double>[10, 20],
                <double>[110, 20],
              ],
            ],
          },
        ],
      },
    ],
  });
}

MokuroBlock _block(MokuroRect rect, String text) {
  return MokuroBlock(
    rectangle: rect,
    isVertical: rect.height > rect.width,
    fontSize: 24,
    zIndex: 0,
    lines: <String>[text],
  );
}

File _writeTempMangaJson() {
  final Directory dir = Directory.systemTemp.createTempSync('manga_writeback_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final File file = File(p.join(dir.path, 'manga.json'));
  file.writeAsStringSync(_mangaJson());
  return file;
}

void main() {
  group('estimateMangaBlockFontSize', () {
    test('面积均摊 + clamp [8, min(宽,高)]', () {
      // 100x100、4 字 → sqrt(10000/4) = 50。
      expect(
        estimateMangaBlockFontSize(width: 100, height: 100, charCount: 4),
        50,
      );
      // 上限：不超 min(宽, 高)（单列竖排不超框宽）。
      expect(
        estimateMangaBlockFontSize(width: 30, height: 300, charCount: 1),
        30,
      );
      // 下限 8。
      expect(
        estimateMangaBlockFontSize(width: 20, height: 20, charCount: 100),
        8,
      );
      // 空文本按 1 字符算，不除零。
      expect(
        estimateMangaBlockFontSize(width: 40, height: 40, charCount: 0),
        40,
      );
    });
  });

  group('writeMangaJsonAtomically', () {
    test('rename 直接覆盖已存在的目标：绝不先 delete（那是唯一的原子性缺口）', () async {
      final File file = _writeTempMangaJson();
      final MokuroPayload payload = parseMangaJson(file.readAsStringSync());
      // 目标已存在时照样写成功。若实现改回「先 delete 再 rename」，delete 与
      // rename 之间目标完全不存在，崩在那个窗口整本 OCR 全丢。
      await writeMangaJsonAtomically(file.path, payload);
      expect(file.existsSync(), isTrue);
      expect(parseMangaJson(file.readAsStringSync()).images, hasLength(2));
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });

    test('源码守卫：writeMangaJsonAtomically 里不得出现 delete()', () {
      // 行为断言证不了「中途没有不存在窗口」（测不到崩溃时刻），只能钉源码。
      final File source = File('lib/src/media/manga/manga_json_writeback.dart');
      final String body = source.readAsStringSync();
      final int start = body.indexOf('Future<void> writeMangaJsonAtomically(');
      expect(start, greaterThan(0));
      final int end = body.indexOf('\n}', start);
      expect(end, greaterThan(start));
      expect(
        body.substring(start, end),
        isNot(contains('.delete()')),
        reason: 'rename 已能覆盖已存在目标（Windows 实测 RENAME_OVER_EXISTING: OK）；'
            '先 delete 再 rename 会开出一个目标不存在的窗口',
      );
    });
  });

  // 锁的价值全在「一个写者都不许漏」。行为测试只能验已经进锁的那些；漏进锁的
  // 调用点必须靠源码扫描抓——这条守卫与文件头的调用点清单是同一份真相。
  group('锁覆盖守卫：书根 manga.json 的每个写/删都在锁内', () {
    test('下载服务不再写 manga.json（票 04 起章元数据是 pages.json）', () {
      // 票 04：在线下载把稳定身份 + 页表写进 `pages.json`，整章 rename 落位；
      // `manga.json` 写侧已随 OCR 移除，不得回流。
      final String body = File(
        'lib/src/media/manga/download/manga_download_service.dart',
      ).readAsStringSync();
      expect(body, isNot(contains('writeMangaJsonAtomically(')));
    });

    test('旧章目录删除 helper 已删除；删除走 Download library 映射', () {
      expect(
        File('lib/src/media/manga/library/manga_chapter_storage.dart')
            .existsSync(),
        isFalse,
        reason: '旧哈希章目录 helper 已随 ticket 12 删除',
      );
      final String body = File(
        'lib/src/media/manga/download/download_library_index.dart',
      ).readAsStringSync();
      expect(body, contains('Future<void> deleteChapter('));
      expect(body, contains('deleteMangaChapterDir('));
    });

    test('阅读器页不再写书根 manga.json（写侧只剩下载服务 / 向导 / 注册表）', () {
      final String body =
          File('lib/src/media/manga/reader/manga_my_comic_page.dart')
              .readAsStringSync();
      expect(body, isNot(contains('writeMangaJsonAtomically(')));
    });

    test('阅读器页不得再自己拼书根 manga.json 的落盘（绕过锁与原子写）', () {
      // 只钉阅读器页：它对书根 manga.json 的写全部应经本模块。
      final String body =
          File('lib/src/media/manga/reader/manga_my_comic_page.dart')
              .readAsStringSync();
      expect(
        body,
        isNot(contains('mangaPayloadToJson(')),
        reason: '直接序列化 payload 就等于绕过 writeMangaJsonAtomically 与 per-path 写锁',
      );
    });
  });

  group('runExclusiveOnMangaJson', () {
    test('同路径严格串行：临界区不重入', () async {
      final File file = _writeTempMangaJson();
      int active = 0;
      int maxActive = 0;
      Future<void> critical() async {
        active++;
        maxActive = maxActive > active ? maxActive : active;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
      }

      await Future.wait(<Future<void>>[
        for (int i = 0; i < 4; i++)
          runExclusiveOnMangaJson<void>(file.path, critical),
      ]);
      expect(maxActive, 1, reason: '同一 manga.json 路径上临界区任何时刻只能有一个执行者');
    });

    test('不同路径互不阻塞（锁按路径分桶，不是全局单锁）', () async {
      final File a = _writeTempMangaJson();
      final File b = _writeTempMangaJson();
      final Completer<void> holdA = Completer<void>();
      final Future<void> first =
          runExclusiveOnMangaJson<void>(a.path, () => holdA.future);
      // b 的临界区不该等 a 释放。
      await runExclusiveOnMangaJson<void>(b.path, () async {}).timeout(
        const Duration(seconds: 2),
      );
      holdA.complete();
      await first;
    });

    // 整卷 OCR 落盘与在线几何回填都是整份覆写，两者都必须经这把锁，否则交叠会
    // 互相覆盖、留下半份 + 半份的拼接。
    test('两个整份覆写者共用一把锁：交叠不丢更新、文件仍合法', () async {
      final File file = _writeTempMangaJson();
      final MokuroPayload baseline = parseMangaJson(file.readAsStringSync());
      final List<MokuroImage> images = List<MokuroImage>.of(baseline.images);
      images[0] = MokuroImage(
        url: images[0].url,
        size: images[0].size,
        blocks: <MokuroBlock>[
          _block(const MokuroRect.fromLTRB(0, 0, 50, 50), 'replaced'),
        ],
      );
      final MokuroPayload edited =
          MokuroPayload(images: images, ocr: baseline.ocr);
      await Future.wait(<Future<void>>[
        runExclusiveOnMangaJson<void>(
          file.path,
          () => writeMangaJsonAtomically(file.path, edited),
        ),
        runExclusiveOnMangaJson<void>(
          file.path,
          () => writeMangaJsonAtomically(file.path, baseline),
        ),
      ]);
      // 两个写者都跑完且文件仍是合法 JSON（不是半份 + 半份的拼接）。
      final MokuroPayload after = parseMangaJson(file.readAsStringSync());
      expect(after.images, hasLength(2));
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });
  });
}
