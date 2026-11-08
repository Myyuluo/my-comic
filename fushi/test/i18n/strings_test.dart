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

    test('确认文案使用新的 local 目录名', () {
      final zh = AppLocale.zhCn.translations;
      expect(
        zh.data_storage_import_local_comics_subtitle,
        '扫描本地漫画文件夹（local），把新作品加入书架；原地读取，不复制、不移动文件。',
      );
      expect(
        zh.manga_series_delete_local_files_confirm,
        '要从 local 删除这部作品的文件夹吗？此操作无法撤销。',
      );
      expect(
        zh.manga_series_remove_local_confirm,
        '把这部作品移出书架？local 中的文件会保留。',
      );
      expect(
        zh.rebuild_download_index_confirm_body,
        '将扫描当前漫画数据位置下的 downloads 与 local：重新关联书架里已有的作品，'
        '并把磁盘上还没入库的作品补进书架。不会移动或删除任何文件；'
        '主动移出书架的作品不会被加回。',
      );

      final en = AppLocale.en.translations;
      expect(
        en.data_storage_import_local_comics_subtitle,
        'Scan the local comics folder (local) and add new works to your library. '
        'Files are read in place; nothing is copied or moved.',
      );
      expect(
        en.manga_series_delete_local_files_confirm,
        'Delete this manga folder from local? This cannot be undone.',
      );
      expect(
        en.manga_series_remove_local_confirm,
        'Remove this manga from the shelf? Files in local will be kept.',
      );
      expect(
        en.rebuild_download_index_confirm_body,
        'my-comic will scan downloads and local under the current manga data '
        'location, re-link books already in your library, and add works found '
        'on disk that are not on your shelf. Files are never moved or deleted; '
        'works you removed from the library are not added back.',
      );
    });
  });
}
