# 09: 导出分类（标签 → Mihon 分类）

**What to build:** 创建备份页增加「分类」勾选项；把 MyComic 的 Tag 导出为 Mihon 分类（名称与顺序），每部导出的 Manga 写入其 Tag 对应的分类 order；分类可以在不导出书架作品时单独导出。

**Blocked by:** 07（创建备份页与导出基础）

**Status:** resolved

- [x] 创建备份页增加「分类」勾选项，默认勾选；「分类」可在未勾选「书架中的作品」时单独导出。
- [x] 每个 Tag 导出为 Mihon 分类，name 为 Tag 名称，order 为 Tag 排序且唯一。
- [x] 每部导出的 Manga 写入其 Tag 对应的分类 order 值；多 Tag 写入多个 order。
- [x] Tag 颜色不导出；导出不新增或修改 Tag。
- [x] 关闭「分类」时分类条目与每部作品的分类字段都不写入。
- [x] 备份 seam 测试覆盖名称、顺序、多 Tag 与单独导出。

## Answer

Implemented in `b7f60db1`, merged into the integration branch as `70790216`.

UI：创建备份页的书架分组新增「分类」勾选项（`create_backup_include_categories`，默认勾选），位于「进度记录」之后，与参考布局的书架组顺序一致。该选项不依赖「书架中的作品」：取消书架时仍可勾选，且仅凭「分类」即可让「创建」保持可用（`MihonBackupExportOptions.includeCategories` 独立传递，不经 `includeLibrary` 门控）。

导出：`fushi/lib/src/backup_export/mihon_backup_exporter.dart` 在 `includeCategories` 时读取 `BookTags`，把每个 Tag 写成一个 Mihon `BackupCategory`：`name` 取 Tag 名称，`order` 取 Tag 排序，`id` 取 Tag id。Mihon 以 order 引用分类，因此 order 必须唯一：`sortOrder < 0` 归零，`BookTags.sortOrder` 冲突（旧数据默认为 0）时顺延到下一个未占用整数；Tag 颜色没有 Mihon 分类字段，不导出。导出只读取 Tag，不新增或修改 Tag。

多 Tag：按 `TagHostKind.epub` 的 Tag 分配，以 book key 聚合每部导出 Manga 的 Tag order，排序后写入 `BackupManga.categoryOrders`；一部作品有多个 Tag 时写入多个 order，没有 Tag 的作品写空列表。

关闭「分类」时不写 `categories`，每部作品的 `categoryOrders` 也为空；分类可单独导出（不勾选「书架中的作品」时仅生成分类与各作品 order）。

测试：`fushi/test/backup_import/mihon_backup_export_roundtrip_test.dart` 覆盖名称、order 唯一化、多 Tag 的 order 列表、单独导出、includeCategories=false 与分类导回 Tag；`fushi/test/backup_import/create_backup_page_test.dart` 覆盖默认勾选、书架依赖与单独导出；合并后 `flutter test test/backup_import/ test/settings/backup_directory_settings_test.dart test/i18n/i18n_keys_sorted_guard_test.dart` 80 项全部通过。
