part of 'mihon_backup_exporter.dart';

/// 「分类」: Tags → Mihon categories.
///
/// Mihon identifies categories inside `BackupManga.categories` by their
/// **order**, so orders must be unique even though `BookTags.sortOrder` is
/// not guaranteed to be (legacy rows default to 0). Display order is the
/// source of truth: tags are visited in [MyComicDatabase.getAllTags] order and
/// a colliding sort order moves to the next free integer. Tag colours have
/// no Mihon category field and are deliberately dropped.
class _CategoryExportSection {
  const _CategoryExportSection(this.database);

  final MyComicDatabase database;

  Future<_CategoryExport> load() async {
    final List<BookTagRow> tags = await database.getAllTags();
    final Set<int> usedOrders = <int>{};
    final Map<int, int> orderByTagId = <int, int>{};
    final List<MihonBackupCategory> categories = <MihonBackupCategory>[];
    for (final BookTagRow tag in tags) {
      int order = tag.sortOrder < 0 ? 0 : tag.sortOrder;
      while (usedOrders.contains(order)) {
        order++;
      }
      usedOrders.add(order);
      orderByTagId[tag.id] = order;
      categories.add(
        MihonBackupCategory(name: tag.name, order: order, id: tag.id),
      );
    }

    final List<TagAssignmentRow> assignments = await database
        .getTagAssignmentsForKind(TagHostKind.epub);
    final Map<String, List<int>> ordersByBookKey = <String, List<int>>{};
    for (final TagAssignmentRow assignment in assignments) {
      final int? order = orderByTagId[assignment.tagId];
      if (order == null) continue;
      ordersByBookKey
          .putIfAbsent(assignment.entryKey, () => <int>[])
          .add(order);
    }
    for (final List<int> orders in ordersByBookKey.values) {
      orders.sort();
    }
    return _CategoryExport(
      categories: List<MihonBackupCategory>.unmodifiable(categories),
      ordersByBookKey: ordersByBookKey,
    );
  }
}

/// Resolved category section: the exported Mihon categories plus each book's
/// category orders (never tag ids — Mihon references categories by order).
class _CategoryExport {
  const _CategoryExport({
    required this.categories,
    required this.ordersByBookKey,
  });

  final List<MihonBackupCategory> categories;
  final Map<String, List<int>> ordersByBookKey;

  List<int> ordersFor(String bookKey) =>
      ordersByBookKey[bookKey] ?? const <int>[];
}
