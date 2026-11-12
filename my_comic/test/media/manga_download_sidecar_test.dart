import 'package:flutter_test/flutter_test.dart';

import 'package:my_comic/src/media/manga/download/manga_download_sidecar.dart';
import 'package:my_comic/src/media/manga/library/online_manga_library_entry.dart';

void main() {
  test('sidecar URL encodes path segments independently', () {
    expect(
      mokuroSidecarUri('series name/part 1', 'Vol 01|special').toString(),
      'https://mokuro.moe/mokuro-reader/series%20name/part%201/Vol%2001%7Cspecial.mokuro',
    );
  });

  test('sidecar identity parses the Mihon chapter URL', () {
    const OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'test.mokuro',
      sourceId: '1',
      series: OnlineMangaSeries(
        key: 'series',
        title: 'Series',
        raw: <String, Object?>{},
      ),
      chapters: <OnlineMangaChapter>[],
    );
    const OnlineMangaChapter chapter = OnlineMangaChapter(
      key: 'https://mokuro.moe/mokuro-reader/series%20name/Vol%2001.cbz',
      name: 'ignored display title',
      raw: <String, Object?>{},
    );
    final MokuroSidecarIdentity? identity = mokuroSidecarIdentity(
      entry,
      chapter,
    );
    expect(identity?.seriesPath, 'series name');
    expect(identity?.volumeName, 'Vol 01');
  });
}
