[根目录](../../CLAUDE.md) > [packages](../) > **my_comic_core**

# my_comic_core

## 模块职责

共享核心模块：定义 Drift SQLite 数据库 schema、表迁移逻辑、偏好键值编解码器（PrefCodec）、语言配置模型和文本选区模型。是所有其他 packages 的基础依赖。

- 当前 `schemaVersion = 5`（`lib/src/database/database.dart` 的 `kMyComicSchemaVersion`；本文数字仅作快照，以代码为准）。
- `@DriftDatabase(tables: [...])` 注册 **99 张表**。MyComic 只使用漫画域子集；其余表是 上游快照的历史 schema，按 spec 要求保留以避免旧备份 / 旧偏好解析崩溃，**不要新增迁移或删除表**。
- 迁移策略：`onUpgrade` 逐版本增量迁移，最低可升级 schema 为 `kMinSupportedSchemaVersion`；低于门槛抛 `UnsupportedLegacySchemaException`，库比代码新抛 `MyComicDatabaseDowngradeException`，都不重建库。

## 入口与启动

- 库入口：`lib/my_comic_core.dart`
- 数据库在 `lib/src/database/database.dart` 中通过 `MyComicDatabase(dbDirectory)` 构造，内部使用 `NativeDatabase.createInBackground()` 在后台线程打开 `my_comic.db`。
- PRAGMA 配置：`journal_mode=WAL`，`foreign_keys=ON`。

## 对外接口

- `MyComicDatabase` -- 全部数据访问层（漫画 / 来源 / 下载 / 历史 / 标签 / 备份 / 偏好等 CRUD）。
- `PrefCodec` -- 偏好值的 `encode<T>` / `decode<T>` 泛型编解码。
- `MyComicTextSelection` -- 跨模块共享的文本选区数据模型。

## 关键依赖与配置

- `drift: ">=2.33.0 <2.34.0"` + `sqlite3` -- ORM 与 SQLite 绑定。**本包零 Flutter**（pubspec 不声明 `sdk: flutter`，包测试用 `package:test`）；SQLite 原生库由消费方装配：app 在 `my_comic/pubspec.yaml` 声明 `sqlite3_flutter_libs`。
- `path: ^1.8.2` -- 路径处理。
- 代码生成：`drift_dev: ^2.23.0` + `build_runner`，生成 `database.g.dart`。

## 数据模型

99 张 Drift 表，按功能分组（以 `database.dart` 的 `@DriftDatabase(tables: [...])` 注册清单为准）：

| 分组 | 表名 |
|------|------|
| 媒体 / 来源 | `MediaOpenHistory`, `MediaSources`, `Series`, `ShelfEntries`, `MediaCollections`, `MediaCollectionItems`, `CollectionRelations` |
| 漫画库 | `MangaChapterStates`, `MangaDownloadJobs`, `MangaChapterDirs`, `MangaReaderOverrides`, `MangaExtensionStores`, `MangaExtensions`, `MangaOnlineSources`, `MangaSourcePreferences`, `MangaTrustedSigners`, `MediaImages` |
| 阅读位置 / 书签 | `ReaderPositions`, `Bookmarks`, `BookCustomCss`, `RevealedImages` |
| 标签 | `BookTags`, `TagAssignments` |
| 偏好 / 活动 | `Preferences`, `ClipboardHistory`, `ActivityEvents`, `UpdateFeedEntries` |
| 备份 / 墓碑 | `BookTombstones`, `StatisticsTombstones`, `CollectionMemberTombstones`, `BookTagMembershipTombstones`, `SyncDeletionTombstones`, `StudySegmentTombstones` |
| 历史非漫画域（兼容保留） | `AnkiMappings`, `SearchHistoryItems`, `Audiobooks`, `AudioCues`, `SrtBooks`, `ReadingStatistics`, `ReadingHourlyLogs`, `DictionaryMetadata`, `DictionaryHistory`, `EpubBooks`, `Profiles`, `ProfileSettings`, `MediaTypeProfiles`, `BookProfiles`, `LanguageProfiles`, `SyncBaselines`, `VideoBooks`, `VideoWatchStatistics`, `VideoHourlyLogs`, `FavoriteWords`, `MiningStatistics`, `MinedSentences`, `LookupMiningCounters`, `CollectionBookAliases`, `MyComicPairedPeers`, `VideoScrapeMeta`, `CollectionScrapeMeta`, `MediaTrackingMappings`, `MediaTrackingOutbox`, `Galgames`, `GalgameSources`, `GalgameSessions`, `VideoMetadata*`, `VideoSourceScrape*`, `VideoSidecarArtifacts`, `VideoDownload*`, `VideoFileSpecs`, `VideoEpisodeBindingOverrides`, `AnidbFileIdentities`, `StudySegments`, `WebMineQueue`, `PendingMineQueue`, `SrsEntities`, `SrsFieldEdits`, `SrsReviewLogs`, `SrsUnknownEvents`, `SrsEventLocal`, `SrsLocalState`, `SrsNotesCache`, `SrsCardsCache` |

## 测试与质量

测试位于 `packages/my_comic_core/test/`（本包目录下，不在 `my_comic/test/`），用 `dart test` 运行，覆盖 fresh schema、迁移降级、偏好编解码、成员关系与快照文件等。

## 相关文件清单

- `lib/my_comic_core.dart` -- 库入口
- `lib/src/database/database.dart` -- 数据库定义与 CRUD
- `lib/src/database/database.g.dart` -- 生成文件（勿手动修改）
- `lib/src/database/tables.dart` -- 全部表定义
- `lib/src/database/pref_codec.dart` -- 偏好编解码
- `lib/src/models/my_comic_text_selection.dart` -- 文本选区模型

## 变更记录 (Changelog)

- 2026-05-23: 初始文档生成。
- 2026-11-12: 更新到 MyComic 独立化后的实际 schemaVersion / 表清单 / 测试路径。
