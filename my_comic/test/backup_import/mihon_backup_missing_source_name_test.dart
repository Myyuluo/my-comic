import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic_core/my_comic_core.dart';
import 'package:path/path.dart' as p;

import 'package:my_comic/src/backup_import/mihon_backup_import_service.dart';
import 'package:my_comic/src/media/manga/library/online_manga_library_entry.dart';

import 'mihon_backup_fixture.dart';

/// 票 04 seam: [MihonBackupImportService.importFile]（文件进、报告出）。
///
/// 备份里的 `BackupSource` 名称要随占位条目一起持久化，作品页才能在来源缺失时
/// 显示「来源未安装：<名称>」；旧描述符没有这个可选字段时必须能照常解析。
void main() {
  late Directory tmp;
  late MyComicDatabase db;
  const int sourceId = 524579092615598717;
  const String sourceName = '再漫画';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mycomic-missing-source-');
    db = MyComicDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  MihonBackupImportService service() => MihonBackupImportService(
    database: db,
    bookDirectory: (String bookKey) async {
      final Directory dir = Directory(p.join(tmp.path, 'books', bookKey));
      await dir.create(recursive: true);
      return dir.path;
    },
    now: () => 1800000000000,
  );

  Future<OnlineMangaLibraryEntry> importedEntry() async {
    final List<EpubBookRow> books = await db.getAllEpubBooks();
    return OnlineMangaLibraryEntry.tryParse(books.single.sourceMetadata)!;
  }

  test('来源未安装：备份里的来源名称写入占位条目的 source metadata', () async {
    final File backup = await writeFixtureBackup(
      tmp,
      sources: const <FixtureSource>[
        FixtureSource(id: sourceId, name: sourceName),
      ],
      mangas: const <FixtureManga>[
        FixtureManga(
          source: sourceId,
          url: '/manga/alpha',
          title: 'Alpha',
          chapters: <FixtureChapter>[
            FixtureChapter(url: '/chapter/1', name: 'Chapter 1'),
          ],
        ),
      ],
    );

    final MihonBackupImportReport report = await service().importFile(backup);

    expect(report.importedEntries, 1);
    expect(
      report.missingSources.single.sourceName,
      sourceName,
      reason: '报告仍然列出缺失来源名称',
    );
    final OnlineMangaLibraryEntry entry = await importedEntry();
    expect(
      entry.extensionPackage,
      kUnavailableMihonExtensionPackage,
      reason: '来源未安装时仍用稳定占位身份',
    );
    expect(entry.sourceId, '$sourceId');
    expect(entry.sourceName, sourceName, reason: '名称进描述符，作品页无需再查 Source 表');
    expect(entry.chapters.single.key, '/chapter/1');
  });

  test('旧备份没有来源名称：sourceName 为空，UI 可退化为「来源未安装」', () async {
    final File backup = await writeFixtureBackup(
      tmp,
      mangas: const <FixtureManga>[
        FixtureManga(source: sourceId, url: '/manga/alpha', title: 'Alpha'),
      ],
    );

    await service().importFile(backup);

    final OnlineMangaLibraryEntry entry = await importedEntry();
    expect(entry.extensionPackage, kUnavailableMihonExtensionPackage);
    expect(entry.sourceName, isNull);
  });

  test('来源已安装：不写占位名称，扩展包保持真实值', () async {
    await db
        .into(db.mangaOnlineSources)
        .insert(
          MangaOnlineSourcesCompanion.insert(
            extensionPackage: 'com.example.ext',
            sourceId: '$sourceId',
            name: '已安装来源',
            language: 'zh',
          ),
        );

    final File backup = await writeFixtureBackup(
      tmp,
      sources: const <FixtureSource>[
        FixtureSource(id: sourceId, name: sourceName),
      ],
      mangas: const <FixtureManga>[
        FixtureManga(source: sourceId, url: '/manga/alpha', title: 'Alpha'),
      ],
    );

    await service().importFile(backup);

    final OnlineMangaLibraryEntry entry = await importedEntry();
    expect(entry.extensionPackage, 'com.example.ext');
    expect(
      entry.sourceName,
      isNull,
      reason: '真实 Source 的名称由 Source 表提供，不复制进条目',
    );
  });

  test('旧描述符没有 sourceName 字段也能解析（向后兼容）', () {
    final Map<String, Object?> json = const OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: kUnavailableMihonExtensionPackage,
      sourceId: '$sourceId',
      series: OnlineMangaSeries(
        key: '/manga/alpha',
        title: 'Alpha',
        raw: <String, Object?>{'url': '/manga/alpha'},
      ),
      chapters: <OnlineMangaChapter>[],
    ).toJson();
    json.remove('sourceName');

    final OnlineMangaLibraryEntry? parsed = OnlineMangaLibraryEntry.tryParse(
      jsonEncode(json),
    );

    expect(parsed, isNotNull);
    expect(parsed!.sourceName, isNull);
  });
}
