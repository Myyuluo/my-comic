import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';

void main() {
  group('Chinese reader settings labels', () {
    test('uses compact labels for furigana modes', () {
      final strings = AppLocale.zhCn.translations;

      expect(strings.reader_furigana_off, '关闭');
      expect(strings.reader_furigana_toggle, '点击显示');
      expect(strings.reader_furigana_hidden, '隐藏');
      expect(strings.reader_furigana_dimmed, '淡显');
      expect(
        strings.reader_furigana_mode_hint,
        '',
      );
    });

    test('makes arrow reverse keyboard-specific', () {
      final strings = AppLocale.zhCn.translations;

      expect(strings.reverse_arrow_page_turn, '反转键盘左右键翻页方向');
    });
  });

  group('Sources view tab labels', () {
    test('zh-CN renames the sources tab to 图源 and the search hint to 搜索图源',
        () {
      final strings = AppLocale.zhCn.translations;

      expect(strings.media_import_segment_sources, '图源');
      expect(strings.mihon_sources_search_hint, '搜索图源');
    });

    test('zh-HK renames the sources tab to 圖源 and the search hint to 搜尋圖源',
        () {
      final strings = AppLocale.zhHk.translations;

      expect(strings.media_import_segment_sources, '圖源');
      expect(strings.mihon_sources_search_hint, '搜尋圖源');
    });

    test('the English baseline stays the neutral Sources', () {
      final strings = AppLocale.en.translations;

      expect(strings.media_import_segment_sources, 'Sources');
      expect(strings.mihon_sources_search_hint, 'Search sources');
    });
  });

  group('Storage location labels', () {
    test('zh-CN renames 漫画数据位置 to 存储位置 and its buttons', () {
      final strings = AppLocale.zhCn.translations;

      expect(strings.data_storage_content_root_title, '存储位置');
      expect(strings.data_storage_change_button, '变更文件夹');
      expect(strings.data_storage_open_button, '打开文件夹');
    });

    test('zh-HK uses the same shorter wording', () {
      final strings = AppLocale.zhHk.translations;

      expect(strings.data_storage_content_root_title, '儲存位置');
      expect(strings.data_storage_change_button, '變更資料夾');
      expect(strings.data_storage_open_button, '開啟資料夾');
    });

    test('the English baseline follows the shorter wording', () {
      final strings = AppLocale.en.translations;

      expect(strings.data_storage_content_root_title, 'Storage location');
      expect(strings.data_storage_change_button, 'Change folder');
      expect(strings.data_storage_open_button, 'Open folder');
    });
  });

  group('Chinese video clip export labels', () {
    test('uses clip export wording consistently', () {
      final strings = AppLocale.zhCn.translations;
      final String formerPixelCaptureTerm =
          String.fromCharCodes(<int>[0x5f55, 0x5c4f]);

      expect(strings.video_clip_export, '片段导出');
      expect(strings.video_clip_export_start, '开始片段导出');
      expect(strings.video_clip_export_stop, '停止并导出片段');
      expect(strings.video_clip_exporting, '正在导出片段…');
      expect(strings.video_clip_export_remote_download_required,
          contains('下载到本机'));
      expect(
          strings.video_clip_export, isNot(contains(formerPixelCaptureTerm)));
      expect(
        strings.video_clip_export_start,
        isNot(contains(formerPixelCaptureTerm)),
      );
      expect(
        strings.video_clip_export_stop,
        isNot(contains(formerPixelCaptureTerm)),
      );
    });
  });

  group('video scrape cleanup labels', () {
    test('direct getters and dynamic flat maps are available in every locale',
        () {
      for (final AppLocale locale in AppLocale.values) {
        final strings = locale.translations;
        expect(
          strings.video_source_scrape_clear_all,
          isNotEmpty,
          reason: '${locale.name} direct getter',
        );
        expect(
          strings['video_source_scrape_clear_all'],
          isNotNull,
          reason: '${locale.name} flat-map lookup',
        );
        expect(
          strings['video_source_scrape_clear_all_in_progress'],
          isNotNull,
          reason: '${locale.name} in-progress flat-map lookup',
        );
      }
      expect(
        AppLocale.zhCn.translations.video_source_scrape_clear_all,
        '清理全部刮削记录',
      );
    });
  });

  group('Local source root rename', () {
    // 只守用户可见文案的**不变量**（旧目录名不得复现）。逐句硬编码文案由各
    // ticket 的专用测试（如 download_cbz_setting_test 对 CBZ 副标题）负责，
    // 这里再抄一遍整句只会随正常文案润色一起碎。
    test('用户可见文案不再出现旧目录名 localcomic', () {
      final List<String> hits = <String>[];
      for (final FileSystemEntity entity in Directory('lib/i18n').listSync()) {
        if (entity is! File || !entity.path.endsWith('.i18n.json')) continue;
        if (entity.readAsStringSync().contains('localcomic')) {
          hits.add(entity.path);
        }
      }
      expect(hits, isEmpty, reason: '旧目录名不得出现在用户可见文案：${hits.join(', ')}');
    });
  });
}
