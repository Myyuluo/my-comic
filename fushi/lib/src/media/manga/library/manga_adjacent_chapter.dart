import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';

/// 规范阅读顺序（第 1 话 → 第 N 话）里「下一话」的下标偏移。
///
/// 阅读顺序是升序，所以下一话是下标 **+1**；源返回的新→旧顺序不是这个列表的
/// 顺序，换章必须先经 [mangaReadingOrder]。
const int kMangaNextChapterStep = 1;

/// 章节的规范阅读顺序（第 1 话 → 第 N 话），与存储数组 / 屏幕显示顺序无关。
///
/// 排序依据（对齐 Mihon 的 source order 排序）：
/// 1. [OnlineMangaChapter.sourceOrder] 降序（0 = 最新一话）；
/// 2. 顺序相同或缺失时回退章节号升序；
/// 3. 再回退上传时间升序（越早越旧）；
/// 4. 仍无法区分时按输入下标降序——源的输入约定是新→旧，所以数组末尾最旧。
///
/// 第 4 条让「完全没有顺序信息」的在线条目保持现有阅读方向；导入条目只要带
/// `sourceOrder`（或章节号 / 日期）就不依赖数组顺序。
List<OnlineMangaChapter> mangaReadingOrder(List<OnlineMangaChapter> chapters) {
  final List<(OnlineMangaChapter, int)> indexed = <(OnlineMangaChapter, int)>[
    for (int i = 0; i < chapters.length; i++) (chapters[i], i),
  ];
  indexed.sort(((OnlineMangaChapter, int) a, (OnlineMangaChapter, int) b) {
    final int? aOrder = a.$1.sourceOrder;
    final int? bOrder = b.$1.sourceOrder;
    if (aOrder != null && bOrder != null && aOrder != bOrder) {
      return bOrder.compareTo(aOrder);
    }
    final double? aNumber = _knownNumber(a.$1);
    final double? bNumber = _knownNumber(b.$1);
    if (aNumber != null && bNumber != null && aNumber != bNumber) {
      return aNumber.compareTo(bNumber);
    }
    final int? aUploaded = a.$1.uploadedAt;
    final int? bUploaded = b.$1.uploadedAt;
    if (aUploaded != null && bUploaded != null && aUploaded != bUploaded) {
      return aUploaded.compareTo(bUploaded);
    }
    return b.$2.compareTo(a.$2);
  });
  return List<OnlineMangaChapter>.unmodifiable(
    indexed.map(((OnlineMangaChapter, int) entry) => entry.$1),
  );
}

/// 判断「最后一章」时使用的章节顺序。
enum MangaChapterOrdering {
  /// 在线 / 导入条目的规范阅读顺序：sourceOrder → 话数 → 上传时间，与存储
  /// 数组顺序无关（[mangaReadingOrder]）。
  canonical,

  /// 本地图源扫描的自然顺序（第 1 话 → 第 N 话）。
  natural,
}

/// [chapters] 里下标 [index] 的章是否是**该顺序的最后一章**。
///
/// [MangaChapterOrdering.canonical] 用于在线 / 导入条目，按 [mangaReadingOrder]
/// 推导；[MangaChapterOrdering.natural] 用于本地图源，与阅读器
/// `_adjacentChapterIndex` 的本地分支一致。用于「读到哪一章的末页才算整部作品
/// 读完」——旧实现任何一章读到末页都写书级 `completedAt`。
bool isLastMangaChapterInReadingOrder({
  required List<OnlineMangaChapter> chapters,
  required int index,
  MangaChapterOrdering ordering = MangaChapterOrdering.canonical,
}) {
  if (index < 0 || index >= chapters.length) return false;
  if (ordering == MangaChapterOrdering.natural) {
    return index == chapters.length - 1;
  }
  if (chapters.length <= 1) return true;
  return mangaReadingOrder(chapters).last.key == chapters[index].key;
}

/// 阅读顺序上与第 [currentIndex] 章相邻的章（[forward] = 往后读），返回它在
/// [chapters] 里的下标；没有可去的章返回 null。
///
/// 对齐 Mihon `ReaderViewModel` 的章节过滤：
/// * [skipRead]：已读章（[readChapterKeys]）不作为落点；当前章本身不受影响。
/// * [skipDuplicate]：与当前章**同话数**的章（多个汉化组的同一话）不作为落点；
///   下一话若有多个版本，优先与当前章同一汉化组的那个，否则取阅读顺序上最先
///   遇到的那个。话数未知（null / 负数）的章不参与去重。
///
/// [chapters] 可以是任意存储顺序：阅读顺序由 [mangaReadingOrder] 按
/// `sourceOrder`（缺失时章节号 / 上传日期）推导。返回值始终是 [chapters] 的
/// 下标，调用方可以继续用 `entry.chapters[index]` 取章。
int? resolveAdjacentMangaChapter({
  required List<OnlineMangaChapter> chapters,
  required int currentIndex,
  required bool forward,
  Set<String> readChapterKeys = const <String>{},
  bool skipRead = false,
  bool skipDuplicate = false,
}) {
  if (currentIndex < 0 || currentIndex >= chapters.length) return null;
  final int step = forward ? kMangaNextChapterStep : -kMangaNextChapterStep;
  final OnlineMangaChapter current = chapters[currentIndex];
  final double? currentNumber = _knownNumber(current);
  final List<OnlineMangaChapter> ordered = mangaReadingOrder(chapters);
  final int orderedCurrent = ordered.indexOf(current);
  if (orderedCurrent < 0) return null;
  // 规范顺序里的章 → 存储数组下标。用 identity map，避免长列表上反复 indexOf。
  final Map<OnlineMangaChapter, int> originalIndexByChapter =
      Map<OnlineMangaChapter, int>.identity();
  for (int i = 0; i < chapters.length; i++) {
    originalIndexByChapter[chapters[i]] = i;
  }

  int originalIndex(OnlineMangaChapter chapter) =>
      originalIndexByChapter[chapter]!;

  bool eligible(OnlineMangaChapter chapter) {
    if (skipRead && readChapterKeys.contains(chapter.key)) return false;
    if (skipDuplicate &&
        currentNumber != null &&
        _knownNumber(chapter) == currentNumber) {
      return false;
    }
    return true;
  }

  for (int i = orderedCurrent + step; i >= 0 && i < ordered.length; i += step) {
    final OnlineMangaChapter candidate = ordered[i];
    if (!eligible(candidate)) continue;
    final double? number = _knownNumber(candidate);
    if (!skipDuplicate || number == null) return originalIndex(candidate);
    // 同一话的多个版本：优先当前汉化组，否则就是第一个遇到的 [i]。
    final String? scanlator = _normalizedScanlator(current);
    if (scanlator == null || _normalizedScanlator(candidate) == scanlator) {
      return originalIndex(candidate);
    }
    for (int j = i + step; j >= 0 && j < ordered.length; j += step) {
      final OnlineMangaChapter sibling = ordered[j];
      if (_knownNumber(sibling) != number) continue;
      if (eligible(sibling) && _normalizedScanlator(sibling) == scanlator) {
        return originalIndex(sibling);
      }
    }
    return originalIndex(candidate);
  }
  return null;
}

/// 预下载下一话的时机：读过当前章约 2/3 之后，或者当前章很短（一进来就下）。
///
/// [currentPage] 从 0 数；[pageCount] 是本章总页数。
bool shouldPrefetchNextMangaChapter({
  required int currentPage,
  required int pageCount,
}) {
  if (pageCount <= 0 || currentPage < 0) return false;
  if (pageCount <= kMangaShortChapterPageCount) return true;
  return (currentPage + 1) * 3 >= pageCount * 2;
}

/// 不超过这么多页的章一打开就预下载下一话：读完它只要几十秒，等到 2/3 处再排
/// 队多半赶不上。
const int kMangaShortChapterPageCount = 8;

double? _knownNumber(OnlineMangaChapter chapter) {
  final double? number = chapter.number;
  if (number == null || !number.isFinite || number < 0) return null;
  return number;
}

String? _normalizedScanlator(OnlineMangaChapter chapter) {
  final String? value = chapter.scanlator?.trim();
  return value == null || value.isEmpty ? null : value;
}
