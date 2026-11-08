import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math' show Random;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
// drift/remote.dart 标了 experimental，但 DriftRemoteException 是后台 isolate 连接
// 抛错的唯一载体，开库时要靠它还原类型化异常（见 _TypedOpenErrorInterceptor）。
// ignore: experimental_member_use
import 'package:drift/remote.dart' show DriftRemoteException;
import 'package:path/path.dart' as p;
import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../utils/fushi_debug_print.dart';
import 'activity_event_types.dart';
import 'book_format.dart';
import 'collection_order.dart';
import 'collection_book_identity.dart';
import 'epub_book_meta.dart';
import 'manga_shelf_read_snapshot.dart';
import 'media_kind.dart';
import 'media_kind_mappings.dart';
import 'pref_codec.dart';
import 'sync_tombstone_kind.dart';
import 'tables.dart';
import 'tag_host_kind.dart';

part 'database.g.dart';
part 'database_infra.part.dart';
part 'database_prefs_media.part.dart';
part 'database_video_domain.part.dart';
part 'database_library.part.dart';
part 'database_statistics.part.dart';
part 'database_content_misc.part.dart';
part 'database_tags_sync.part.dart';
part 'database_update_feed.part.dart';
part 'database_manga_download.part.dart';
part 'database_srs.part.dart';

/// Thrown when the on-disk database was created by a NEWER build of Fushi than
/// the one currently running (`db user_version > code schemaVersion`).
///
/// 降级保护：当用户用旧版应用打开由新版创建的库时，绝不 DROP/迁移/重建，而是抛出此
/// 异常让打开失败、事务回滚、库文件原样保留，并由 UI 提示用户更新应用。这是修复
/// 「旧 app 启动把用户数据库降级破坏」整类事故的根因拦截。
class FushiDatabaseDowngradeException implements Exception {
  /// The schema version stored in the on-disk DB file (created by a newer app).
  final int dbVersion;

  /// The schema version this (older) build of the code knows about.
  final int appSchemaVersion;

  const FushiDatabaseDowngradeException({
    required this.dbVersion,
    required this.appSchemaVersion,
  });

  @override
  String toString() =>
      'FushiDatabaseDowngradeException: database was created by a newer '
      'version of Fushi (schema v$dbVersion); this app only understands '
      'schema v$appSchemaVersion. Opening was refused to protect your data.';
}

/// 本版本仍能原地升级的最低库 schema（含）。低于它的迁移阶梯（Hibiki 时代的
/// `hibiki_paired_peers` / `reader_ttu` / `sasayaki` / `hoshi://` /
/// `s:hibikiServer` 等存量改写，最高到 v74）已从本版本删除。
///
/// 选 75 的依据：最后一条改写旧字面量的台阶是 v74；改名后首个正式版 v2.2.4
/// 出货的已是 schema v94，此后所有正式版都 ≥ 94，只有停在改名前（Hibiki v2.1.1
/// 及更早，schema ≤ 68）或从未升级过的库会落到门槛以下。这类库要先装
/// [kLegacySchemaBridgeAppVersion]（仍带完整阶梯）打开一次升级，再装本版本。
const int kMinSupportedSchemaVersion = 75;

/// 仍带完整迁移阶梯、可把门槛以下老库升上来的最新正式版（UI 提示用户先装它）。
const String kLegacySchemaBridgeAppVersion = '2.9.1';

/// [kLegacySchemaBridgeAppVersion] 的 GitHub Release 页（门槛提示里的下载链接）。
/// 2026-10-14 经 `gh release view v2.9.1` 核实：正式版、非预发布。
const String kLegacySchemaBridgeReleaseUrl =
    'https://github.com/hajisensai/fushi/releases/tag/'
    'v$kLegacySchemaBridgeAppVersion';

/// 库的 schema 低于 [kMinSupportedSchemaVersion]（或目录里只有改名前的
/// `hibiki.db`），本版本已不含能把它升上来的迁移代码。
///
/// 与 [FushiDatabaseDowngradeException] 同一套拦截方式：在 drift 最早的迁移钩子里
/// 抛出，迁移事务不提交、`user_version` 不前移、库文件原样保留；绝不建空库顶替。
/// app 层识别这个类型，提示用户先装 [kLegacySchemaBridgeAppVersion] 打开一次再更新。
/// 备份恢复 / 合并导入在覆盖或合并前用 [checkSupportedSchemaVersion] 做同样的判定。
class UnsupportedLegacySchemaException implements Exception {
  /// 库里的 schema（`PRAGMA user_version`）；只发现旧文件名 `hibiki.db` 而未读
  /// 版本时为 null。
  final int? dbVersion;

  /// 本版本支持的最低 schema（[kMinSupportedSchemaVersion]）。
  final int minSupportedVersion;

  /// 触发拒绝的文件路径（诊断用；可为 null）。
  final String? dbPath;

  const UnsupportedLegacySchemaException({
    required this.dbVersion,
    this.minSupportedVersion = kMinSupportedSchemaVersion,
    this.dbPath,
  });

  @override
  String toString() =>
      'UnsupportedLegacySchemaException: database '
      '${dbPath == null ? '' : '"$dbPath" '}'
      '(schema ${dbVersion == null ? 'pre-rename hibiki.db' : 'v$dbVersion'}) '
      'is older than the minimum this version can upgrade '
      '(schema v$minSupportedVersion). Install Fushi '
      'v$kLegacySchemaBridgeAppVersion, open it once to upgrade the data, then '
      'install this version ($kLegacySchemaBridgeReleaseUrl). The database '
      'was left untouched.';
}

/// 判定一个外来库的 schema 能否被本版本接手（备份恢复 / 合并导入 / 迁移导入在
/// 覆盖或合并之前调用）。`0`（非 drift 库 / 空文件）不归本函数管，交给原有校验。
void checkSupportedSchemaVersion(int userVersion, {String? dbPath}) {
  if (userVersion > 0 && userVersion < kMinSupportedSchemaVersion) {
    throw UnsupportedLegacySchemaException(
      dbVersion: userVersion,
      dbPath: dbPath,
    );
  }
}

/// 从 SQLite 文件头读 `user_version`（偏移 60，4 字节大端）。[header] 不足 64
/// 字节或不是 SQLite 文件头时返回 null。只读文件头，不开连接、不碰 `-wal`。
int? sqliteUserVersionFromHeader(List<int> header) {
  const List<int> magic = <int>[
    0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66, //
    0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00,
  ];
  if (header.length < 64) return null;
  for (int i = 0; i < magic.length; i++) {
    if (header[i] != magic[i]) return null;
  }
  return (header[60] << 24) | (header[61] << 16) | (header[62] << 8) | header[63];
}

/// Thrown when the database could NOT be opened even after the full WAL/IOERR
/// recovery ladder (checkpoint → DELETE journal → physical sidecar rebuild)
/// ran — i.e. the main `fushi.db` file itself is corrupt, not just a stale
/// `-wal` / `-shm` sidecar. Mirrors [FushiDatabaseDowngradeException]: it is a
/// dedicated, app-recognisable terminal type so the app layer can show an
/// actionable "import a backup / clear data" notice INSTEAD of looping the
/// generic init-error Retry button forever (TODO-905 root cause: a stale
/// sidecar made `PRAGMA journal_mode=WAL` raise SqliteException(1546), and Retry
/// re-ran open against the same untouched bad sidecar = infinite "can't open").
/// BUG-1899：终态失败的两种**根本不同**的成因。此前它们共用一句「likely corrupt,
/// must be restored from a backup or cleared」，把「路径压根打不开」说成了「数据坏了」，
/// 并把用户引向清空数据——而那种情况下磁盘上一个字节都没损坏。
enum FushiDatabaseFailureKind {
  /// 文件在，但内容不是合法的 SQLite（或恢复阶梯已穷尽）。真的坏了：只能恢复备份或清空。
  corrupt,

  /// 根本打不开：父目录不存在、无权限、只读介质、盘断链。
  /// **磁盘上什么都没坏**，让用户去清空数据是有害的误导。
  cannotOpen,
}

class FushiDatabaseUnrecoverableException implements Exception {
  /// Absolute path of the database file that could not be recovered.
  final String dbPath;

  /// The underlying error from the final open attempt (kept for diagnostics).
  final Object cause;

  /// 区分「文件坏了」与「路径打不开」，见 [FushiDatabaseFailureKind]。
  final FushiDatabaseFailureKind kind;

  const FushiDatabaseUnrecoverableException({
    required this.dbPath,
    required this.cause,
    this.kind = FushiDatabaseFailureKind.corrupt,
  });

  @override
  String toString() => switch (kind) {
        FushiDatabaseFailureKind.corrupt =>
          'FushiDatabaseUnrecoverableException: the database file at "$dbPath" '
              'could not be opened even after WAL/sidecar recovery. It is '
              'likely corrupt and must be restored from a backup or cleared. '
              'Cause: $cause',
        FushiDatabaseFailureKind.cannotOpen =>
          'FushiDatabaseUnrecoverableException: the database file at "$dbPath" '
              'could not be opened and does not exist on disk — the folder is '
              'missing, unwritable, or on a disconnected/read-only volume. '
              'Nothing is corrupt; check the data location. Cause: $cause',
      };
}

/// SQLite primary result codes that a stale/locked/corrupt `-wal`/`-shm`
/// sidecar surfaces as when opening + switching to WAL after a hard kill:
///   - 10 = `SQLITE_IOERR` family (1546 = `SQLITE_IOERR_SHMOPEN`, SHMMAP, …) —
///     the exact code reported in TODO-905 (Windows mmap-lock residue);
///   - 14 = `SQLITE_CANTOPEN` family (526 = `SQLITE_CANTOPEN_*`) — the same
///     hard-kill residue surfaces here on other OS/state combinations
///     (e.g. a sidecar SQLite can't open/recreate).
/// Both mean "the MAIN db may be fine but a sidecar is the problem". Recovery
/// triggers on either, then PROVES the main db is healthy (read-only open) before
/// touching anything — so a genuinely missing/corrupt/permission-denied main db
/// is NOT mistaken for a sidecar problem (it falls through to unrecoverable).
const int _kSqliteIoErr = 10; // SQLITE_IOERR
const int _kSqliteCantOpen = 14; // SQLITE_CANTOPEN
const int _kSqliteNotADb = 26; // SQLITE_NOTADB

bool _isSidecarOpenError(Object e) {
  if (e is! sqlite3.SqliteException) return false;
  final int primary = e.extendedResultCode & 0xFF;
  // IOERR(10) / CANTOPEN(14): the classic hard-kill sidecar residue. NOTADB(26):
  // a non-SQLite-header file — could be a corrupt MAIN db, so it also enters the
  // ladder, where _mainDbIsHealthy() proves whether the main db is fine (recover)
  // or itself bad (terminal). All three are gated by the health probe below, so
  // a corrupt main db is never mistaken for a stale sidecar.
  return primary == _kSqliteIoErr ||
      primary == _kSqliteCantOpen ||
      primary == _kSqliteNotADb;
}

/// The 16-byte magic header every SQLite database file starts with
/// ("SQLite format 3\u0000"). See https://www.sqlite.org/fileformat.html .
final List<int> _kSqliteMagic = 'SQLite format 3\u0000'.codeUnits; // 16 bytes

/// Whether the MAIN `fushi.db` file is itself a structurally valid SQLite
/// database, judged ONLY by its file header — deliberately WITHOUT opening a
/// connection (a read-only open of a WAL db still engages the `-wal`/`-shm`
/// sidecar, which is the very thing that is broken here, so it would falsely
/// report a healthy main db as bad). Gates sidecar recovery: we only ever delete
/// `-wal`/`-shm` when the main db's header is intact, so a corrupt/missing main
/// db can never be mistaken for a stale sidecar (it stays unrecoverable instead
/// of triggering a destructive delete).
bool _mainDbHeaderIsValid(String path) {
  final File file = File(path);
  if (!file.existsSync()) return false;
  try {
    final RandomAccessFile raf = file.openSync();
    try {
      if (raf.lengthSync() < _kSqliteMagic.length) return false;
      final List<int> head = raf.readSync(_kSqliteMagic.length);
      for (int i = 0; i < _kSqliteMagic.length; i++) {
        if (head[i] != _kSqliteMagic[i]) return false;
      }
      return true;
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return false;
  }
}

/// Opens [dbFile] robustly. Layer 0 is the normal fast path; only a
/// sidecar-class open error (stale/locked/corrupt `-wal`/`-shm` after a hard
/// kill) drops into the recovery ladder. [allowSidecarDelete] gates the physical
/// sidecar rebuild (Layer 2): only the MAIN process may delete `-wal`/`-shm`; the
/// separate `:popup` process passes false and backs off (throws) so two
/// processes never race to delete the same sidecar (TODO-905 D3).
///
/// Throws [FushiDatabaseUnrecoverableException] when the main DB file itself is
/// corrupt (recovery exhausted) so the app layer can stop the Retry loop.
Future<QueryExecutor> _openWithRecovery(
  File dbFile, {
  required bool allowSidecarDelete,
}) async {
  final String path = dbFile.path;
  void applyPragmas(CommonDatabase db) {
    // BUG-772：busy_timeout 前置，让下面的 journal_mode=WAL 切换本身也受 5s busy 超时
    // 约束——视频硬崩留脏 -wal/-shm 时，probe-open 的 WAL 切换可能因锁争用长阻塞 UI
    // isolate（与主 raster 根因并存的独立同步冻结隐患）。
    db.execute('PRAGMA busy_timeout = 5000');
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA foreign_keys = ON');
  }

  // ── Layer 0 — normal path. Probe-open with a raw sqlite3 connection applying
  //    the exact same PRAGMAs drift would. This surfaces the open error eagerly
  //    (createInBackground would otherwise defer it to the first query). On
  //    success we close the probe and hand drift a fresh background connection.
  try {
    final sqlite3.Database probe = sqlite3.sqlite3.open(path);
    try {
      applyPragmas(probe);
    } finally {
      probe.close();
    }
    return NativeDatabase.createInBackground(dbFile, setup: applyPragmas);
  } catch (e, stack) {
    // Not a sidecar-class error → nothing recovery can safely do, surface it.
    if (!_isSidecarOpenError(e)) rethrow;
    // The error class is ambiguous (a corrupt MAIN db can also raise
    // CANTOPEN/NOTADB): only recover if the main db's header is a valid SQLite
    // file. Otherwise it is a corrupt/missing main db → terminal, do NOT delete
    // any sidecar.
    if (!_mainDbHeaderIsValid(path)) {
      // BUG-1899：这里必须分清两件事。sqlite 的 open 在父目录存在时会**自己创建**
      // 缺失的 db 文件，所以走到这一步还「文件不存在」，只可能是连创建都失败了 ——
      // 目录不存在 / 无权限 / 只读介质 / 盘断链。那不是「损坏」，把它说成损坏会把
      // 用户引去清空数据（用户报告：自定义数据安装位置后启动即「Database damaged」，
      // 实际只是 `<dataRoot>/support` 这个空目录没被创建）。
      // 文件确实在但头不是 SQLite magic → 才是真的坏了。
      throw FushiDatabaseUnrecoverableException(
        dbPath: path,
        cause: e,
        kind: File(path).existsSync()
            ? FushiDatabaseFailureKind.corrupt
            : FushiDatabaseFailureKind.cannotOpen,
      );
    }
    fushiDebugPrint('[fushi-db] sidecar open error on "$path" '
        '(main db healthy → recovering): $e\n$stack');
  }

  // ── Layer 1 — checkpoint the WAL back into the main DB, then leave WAL mode.
  //    A raw connection that does NOT pre-set WAL can usually still open even
  //    when a stale -shm is poisoned; wal_checkpoint(TRUNCATE) flushes every
  //    already-committed WAL frame into fushi.db (NO DATA LOSS), then
  //    journal_mode=DELETE drops the -wal/-shm cleanly. MUST run before any
  //    physical sidecar delete (Layer 2) so committed-but-uncheckpointed
  //    transactions are preserved.
  try {
    final sqlite3.Database recover = sqlite3.sqlite3.open(path);
    try {
      recover.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      recover.execute('PRAGMA journal_mode=DELETE');
    } finally {
      recover.close();
    }
    fushiDebugPrint(
        '[fushi-db] Layer 1 recovery OK (checkpoint+DELETE) for "$path"');
    return NativeDatabase.createInBackground(dbFile, setup: applyPragmas);
  } catch (e, stack) {
    if (!_isSidecarOpenError(e)) rethrow;
    fushiDebugPrint('[fushi-db] Layer 1 still failing on "$path": $e\n$stack');
  }

  // ── Layer 2 — physical sidecar rebuild. Layer 1 could not even open a raw
  //    connection (sidecar too poisoned). Only the MAIN process is allowed to
  //    delete; the :popup process backs off so the two never race.
  if (!allowSidecarDelete) {
    throw FushiDatabaseUnrecoverableException(
      dbPath: path,
      cause: 'sidecar open error in a non-main (:popup) process; backing off '
          'so the main process performs sidecar recovery first',
    );
  }
  await _rebuildSidecar(dbFile);
  try {
    return NativeDatabase.createInBackground(dbFile, setup: applyPragmas);
  } catch (e, stack) {
    if (!_isSidecarOpenError(e)) rethrow;
    // ── Layer 3 — sidecar gone yet still failing ⇒ the main fushi.db is
    //    corrupt after all. Terminal: hand the app a recognisable type so it can
    //    stop the Retry loop and offer restore/clear instead of looping.
    fushiDebugPrint(
        '[fushi-db] Layer 2 rebuild failed, DB unrecoverable: $e\n$stack');
    throw FushiDatabaseUnrecoverableException(dbPath: path, cause: e);
  }
}

/// Layer 2 helper: snapshot then physically remove the stale `-wal` / `-shm`
/// sidecars so SQLite rebuilds them from a clean `fushi.db`.
///
/// 🔴 Data-safety invariant (TODO-905 red line): this NEVER touches the main
/// `.db` file — it only deletes the `$path-wal` / `$path-shm` suffixes. A
/// `.corrupt-bak` snapshot of the main DB + each sidecar is taken first (mirrors
/// backup_service's `.pre-restore.bak`) so a user can hand-recover the last
/// un-checkpointed writes if needed.
///
/// Exact names produced (the whitelist in [databaseSnapshotMainFileName] must
/// match these verbatim): `fushi.db.corrupt-bak-<stamp>.db`,
/// `fushi.db.corrupt-bak-<stamp>.db-wal`, `fushi.db.corrupt-bak-<stamp>.db-shm`
/// — the copied file's own extension is appended AFTER the stamp, so a snapshot
/// never ends in a bare `-wal` / `-shm`.
Future<void> _rebuildSidecar(File dbFile) async {
  final String path = dbFile.path;
  final File wal = File('$path-wal');
  final File shm = File('$path-shm');

  // Snapshot the main DB + sidecars before deleting anything (D1: 数据安全兜底).
  final String stamp = DateTime.now().millisecondsSinceEpoch.toString();
  Future<void> snapshot(File src, String suffix) async {
    if (await src.exists()) {
      try {
        await src.copy('$path.corrupt-bak-$stamp$suffix');
      } catch (e) {
        fushiDebugPrint(
            '[fushi-db] snapshot of "${src.path}" failed (non-fatal): $e');
      }
    }
  }

  await snapshot(dbFile, '.db');
  await snapshot(wal, '.db-wal');
  await snapshot(shm, '.db-shm');

  // Delete ONLY the sidecar PATHS; the main .db is left byte-for-byte intact.
  // Handles either a normal sidecar file OR a stray directory occupying the
  // path (a hard kill can leave the path unusable as a file — the cause of the
  // CANTOPEN); both are removed so SQLite can recreate a clean sidecar.
  Future<void> deleteSidecar(String sidecarPath) async {
    final FileSystemEntityType type = await FileSystemEntity.type(sidecarPath);
    if (type == FileSystemEntityType.file) {
      await File(sidecarPath).delete();
    } else if (type == FileSystemEntityType.directory) {
      await Directory(sidecarPath).delete(recursive: true);
    }
  }

  await deleteSidecar('$path-wal');
  await deleteSidecar('$path-shm');
  fushiDebugPrint('[fushi-db] Layer 2: deleted stale -wal/-shm for "$path" '
      '(main .db untouched, .corrupt-bak-$stamp snapshot kept)');
}

/// my-comic 的全新漫画-only schema 版本。
///
/// my-comic 不迁移、不读取、不兼容 Fushi 的旧库（ADR-0002）。版本号从 1 重新起算，
/// 维护自己的迁移链；Fushi 的 v1-v118 阶梯已从本代码库删除。
///
/// - v2：Download library 的章节映射表（storage-layout 票 04）。
/// - v3：章节映射表增加 `container_kind`（folder / archive；CBZ 票 06）。
/// - v4：下载任务状态值域新增 `paused`（全局暂停，ticket 07）。状态是 TEXT 列，
///   但表级 `CHECK (status IN (...))` 必须重建表才能放宽——SQLite 不支持原地改
///   CHECK。
const int kMyComicSchemaVersion = 4;

/// my-comic 主库文件名（与 Fushi 的 `fushi.db` 不同）。
///
/// 换名是「不读取旧 DB」的结构性保证：应用只会打开这个文件，磁盘上遗留的
/// `fushi.db` / `hibiki.db` 永远不会被打开、迁移或改写。
const String kMyComicDatabaseFileName = 'my_comic.db';

/// 主库在 support 根下的文件名。唯一真相源：除了 [_openDb] 自身，app 层判定「这台机器
/// 上是否已经有一个跑过的安装」时也要认这个文件（见 `AppPaths` 的默认 documents
/// 布局判据），故抽成导出常量而不是各处重复字面量。
const String fushiDatabaseFileName = kMyComicDatabaseFileName;

/// Fushi 旧主库文件名（只用于磁盘残留识别/清理，**绝不打开**）。
const String fushiLegacyDatabaseFileName = 'fushi.db';

/// Fushi 改名前的 Hibiki 时代库名（只用于磁盘残留识别/清理，**绝不打开**）。
const String legacyHibikiDatabaseFileName = 'hibiki.db';

/// my-comic 全新 schema 创建的表集合（SQLite 实际表名）。
///
/// 与 [FushiDatabase.migration] 的 `onCreate` 逐张对应；schema 测试钉死两边一致。
/// 这是「漫画-only」的验收面：多一张 = 旧域回流，少一张 = 漫画功能缺表。
const Set<String> kMyComicSchemaTableNames = <String>{
  // 设备级偏好与 Profile
  'preferences',
  'profiles',
  'profile_settings',
  'media_type_profiles',
  'book_profiles',
  'language_profiles',
  // Library / Local source / Category（合集、标签、系列、书架序）
  'media_sources',
  'epub_books',
  'book_tags',
  'tag_assignments',
  'series',
  'shelf_entries',
  'media_collections',
  'media_collection_items',
  'collection_member_tombstones',
  'collection_book_aliases',
  'book_tombstones',
  'book_tag_membership_tombstones',
  // History / Reading progress
  'media_open_history',
  'search_history_items',
  'reader_positions',
  'revealed_images',
  'activity_events',
  // 阅读时长（漫画统计口径）
  'study_segments',
  'study_segment_tombstones',
  // Tracking
  'media_tracking_mappings',
  'media_tracking_outbox',
  // Extension / Source
  'manga_extension_stores',
  'manga_extensions',
  'manga_online_sources',
  'manga_source_preferences',
  'manga_trusted_signers',
  'update_feed_entries',
  // Download
  'manga_download_jobs',
  'manga_chapter_dirs',
  // Reader 每作品覆盖与每章状态
  'manga_chapter_states',
  'manga_reader_overrides',
  // 删除传播墓碑（漫画删除路径仍写入）
  'sync_deletion_tombstones',
};

/// 主库**快照残留**的识别口径（BUG-1870；存储页「数据库备份快照」条目与
/// [deleteDatabaseSnapshotFiles] 共用，展示什么就删什么）。
///
/// 判据是**两层**，缺一层就会误删活数据：
///
/// **层 (a) 形态白名单（本函数）** —— 只认代码**真的产过**的「整文件副本」命名，
/// 逐条列举，不做「不在排除表里就算残留」的黑名单推断：
///
/// - [_rebuildSidecar] 的崩溃恢复快照：`<主库名>.corrupt-bak-<毫秒戳>.db`
///   / `.db-wal` / `.db-shm`（副本名以 `.db*` 结尾，不是 `-wal`/`-shm`）；
/// - 旧版降级救援副本（`from > to` 的销毁式分支早已删除，只在老用户盘上留着）：
///   `<主库名>[-wal|-shm].bak.v<旧schema>.<毫秒戳>`；
/// - `backup_service` 的导入前快照：`<主库名>.pre-restore.bak`
///   / `<主库名>.pre-merge.bak`。
///
/// 黑名单在这里是**危险**的：`backup_service` 把一整族**活控制文件**放在同一个
/// support 根、且同样以主库名开头 —— `fushi.db.sync-preserve.json`（待恢复标记）、
/// `fushi.db.merge-preserve.json`、`fushi.db.merge-src[-wal|-shm]`、
/// `fushi.db.merge-preview-src`。它们不是副本，删掉会让 `recoverPendingRestore`
/// 在下次启动时静默 `return`，用户的 LAN 配对 / 同步基线 / 被排除的 settings、
/// profiles 层永久丢失。白名单让「新加一个控制文件」默认安全（不认识 ⇒ 不碰），
/// 黑名单则默认危险（忘了补一行 ⇒ 可删）。
///
/// **层 (b) 所有权门控（[isDeletableDatabaseSnapshot]）** —— 形态命中也未必是
/// 残留：`pre-restore.bak` 由 `sync-preserve.json` 持有、`pre-merge.bak` 由
/// `merge-preserve.json` 持有。恢复流程半途失败时**两个文件都会被刻意保留**，
/// 下次启动靠它们补完（见 `backup_service.recoverPendingRestore`）。只要 sidecar
/// 还在，被它拥有的副本就是活的恢复输入，不得列出、不得删除；sidecar 不在时它
/// 才是孤儿。「能不能删」因此由「有没有活的恢复流程指向它」这个真实关系决定，
/// 而不是由文件名碰巧不在某个排除表里决定。
///
/// 活库本体与 `-wal` / `-shm` / `-journal` 侧车形态上就不在白名单里，结构上永远
/// 不可能命中（改名前的活库 `hibiki.db` 同样不命中——它会被 [_openDb] 拒绝打开，
/// 绝不能被当成残留删掉）。
bool isDatabaseSnapshotFileName(final String name) =>
    databaseSnapshotMainFileName(name) != null;

/// 崩溃恢复快照后缀（[_rebuildSidecar]：`.corrupt-bak-<stamp>` + 被复制文件的
/// `.db` / `.db-wal` / `.db-shm`）。
final RegExp _kCorruptBakSuffix =
    RegExp(r'^\.corrupt-bak-\d+\.db(-wal|-shm)?$');

/// 旧降级救援副本后缀（`.bak.v<旧schema>.<毫秒戳>`）。
final RegExp _kLegacyDowngradeBakSuffix = RegExp(r'^\.bak\.v\d+\.\d+$');

/// `backup_service` 导入前快照的后缀（只挂主库名，不挂侧车名）。
const List<String> _kImportBakSuffixes = <String>[
  '.pre-restore.bak',
  '.pre-merge.bak',
];

/// 层 (b) 的所有权表：**快照文件名 → 持有它的恢复流程标记文件名**。真相源是
/// `backup_service`（`_preserveSidecar` / `_mergeSidecar` 与 `recoverPendingRestore`
/// / `recoverMergeRestore` 的成对删除）。
const Map<String, String> _kSnapshotOwnerSidecar = <String, String>{
  '$fushiDatabaseFileName.pre-restore.bak':
      '$fushiDatabaseFileName.sync-preserve.json',
  '$fushiDatabaseFileName.pre-merge.bak':
      '$fushiDatabaseFileName.merge-preserve.json',
  // Fushi 旧主库名留下的同名快照：my-comic 不再导入 `.fushi.zip`，但如果磁盘
  // 上还留着旧备份流程的 sidecar，仍按「活恢复输入」保守处理，不自动删。
  '$fushiLegacyDatabaseFileName.pre-restore.bak':
      '$fushiLegacyDatabaseFileName.sync-preserve.json',
  '$fushiLegacyDatabaseFileName.pre-merge.bak':
      '$fushiLegacyDatabaseFileName.merge-preserve.json',
};

/// 层 (a)：[name] 命中快照白名单时返回它所属的主库名（[fushiDatabaseFileName] 或
/// [legacyHibikiDatabaseFileName]），否则返回 null。存储页用它给聚合条目起
/// 「实际命中的是哪个库名」的标题，形态判定因此只有这一份实现。
String? databaseSnapshotMainFileName(final String name) {
  for (final String db in const <String>[
    fushiDatabaseFileName,
    fushiLegacyDatabaseFileName,
    legacyHibikiDatabaseFileName,
  ]) {
    if (!name.startsWith(db)) continue;
    // 旧降级救援把活库的 `-wal` / `-shm` 也整份复制过，所以词干允许带侧车后缀；
    // 长的先试，否则 `hibiki.db-wal.bak.v20.1` 会先被裸库名截走。
    for (final String stem in <String>['$db-wal', '$db-shm', db]) {
      if (!name.startsWith(stem)) continue;
      final String rest = name.substring(stem.length);
      if (_kLegacyDowngradeBakSuffix.hasMatch(rest)) return db;
      if (stem == db &&
          (_kCorruptBakSuffix.hasMatch(rest) ||
              _kImportBakSuffixes.contains(rest))) {
        return db;
      }
      break;
    }
    return null;
  }
  return null;
}

/// 层 (b)：返回**可能**持有 [name] 的恢复流程标记文件名；null = 没有任何流程会
/// 持有它（形态上就是纯残留副本）。
String? databaseSnapshotOwnerFileName(final String name) =>
    _kSnapshotOwnerSidecar[name];

/// 「这个文件现在可以列出/删除吗」的**唯一**对外判据：形态命中白名单，且没有活
/// 的恢复流程持有它。[siblingFileNames] 是该文件所在目录的直接子项名集合
/// （存储页在扫描 isolate 里已经有这份清单，无需二次 IO）。
bool isDeletableDatabaseSnapshot(
  final String name,
  final Set<String> siblingFileNames,
) {
  if (!isDatabaseSnapshotFileName(name)) return false;
  final String? owner = databaseSnapshotOwnerFileName(name);
  return owner == null || !siblingFileNames.contains(owner);
}

/// [supportRoot] **直接**子层里可删的主库快照残留（同步、不递归、不追 symlink；
/// 存储页在扫描 isolate 里调用）。所有权门控的兄弟名集合取自同一次 listSync，
/// 所以「列出」与「删除」看到的是同一个目录快照。
List<File> listDatabaseSnapshotFiles(final Directory supportRoot) {
  if (!supportRoot.existsSync()) return const <File>[];
  final List<FileSystemEntity> children =
      supportRoot.listSync(followLinks: false);
  final Set<String> names = <String>{
    for (final FileSystemEntity e in children) p.basename(e.path),
  };
  return <File>[
    for (final FileSystemEntity e in children)
      if (e is File && isDeletableDatabaseSnapshot(p.basename(e.path), names))
        e,
  ];
}

/// [deleteDatabaseSnapshotFiles] 的结果。删除是**逐文件容错**的：Windows 上
/// Defender / 索引器临时占住某个副本是常态，一个失败就整批中止会让用户点了删除
/// 却几十个文件一个没少。
class DatabaseSnapshotDeletionResult {
  const DatabaseSnapshotDeletionResult({
    required this.deleted,
    required this.failures,
  });

  /// 已删除的绝对路径。
  final List<String> deleted;

  /// 删不掉的：路径 → 失败原因（原样带给 UI 提示，不吞）。
  final Map<String, String> failures;

  bool get hasFailures => failures.isNotEmpty;
}

/// 删除 [supportRoot] 下全部可删的主库快照残留。识别口径与
/// [listDatabaseSnapshotFiles] 同源（含所有权门控），故活库/侧车/待恢复副本结构
/// 上不可能被删到。单个文件删不掉不中止整批：收集失败原因后继续删剩下的。
Future<DatabaseSnapshotDeletionResult> deleteDatabaseSnapshotFiles(
    final Directory supportRoot) async {
  final List<String> deleted = <String>[];
  final Map<String, String> failures = <String, String>{};
  for (final File f in listDatabaseSnapshotFiles(supportRoot)) {
    try {
      await f.delete();
      deleted.add(f.path);
    } on FileSystemException catch (e) {
      failures[f.path] = e.osError?.message ?? e.message;
    }
  }
  return DatabaseSnapshotDeletionResult(deleted: deleted, failures: failures);
}

/// 开库拒绝类异常（[FushiDatabaseDowngradeException] /
/// [UnsupportedLegacySchemaException]）是 app 层**按类型分派**的契约：各自对应一块
/// 专屏 / 一句提示。但生产开库走后台 isolate 的 drift 连接，迁移钩子在调用方 isolate
/// 里抛出的异常要经 drift 的请求通道绕一圈回来，到调用方手里已被包成（可能多层）
/// [DriftRemoteException]——`on FushiDatabaseDowngradeException` 永远接不住，用户
/// 只看到通用错误屏和一个无效的「重试」。这里在开库这一步把它们原样还原。
class _TypedOpenErrorInterceptor extends QueryInterceptor {
  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) async {
    try {
      return await executor.ensureOpen(user);
    } on DriftRemoteException catch (e, stack) {
      Object cause = e;
      StackTrace? causeStack = stack;
      while (cause is DriftRemoteException) {
        causeStack = cause.remoteStackTrace ?? causeStack;
        cause = cause.remoteCause;
      }
      if (cause is FushiDatabaseDowngradeException ||
          cause is UnsupportedLegacySchemaException) {
        Error.throwWithStackTrace(cause, causeStack ?? stack);
      }
      rethrow;
    }
  }
}

LazyDatabase _openDb(String dbDirectory, {bool isMainProcess = true}) {
  return LazyDatabase(() async {
    // 只打开 my-comic 自己的库文件。磁盘上遗留的 Fushi `fushi.db` /
    // `hibiki.db` 结构上永远不会被这个连接看到。
    final file = File(p.join(dbDirectory, fushiDatabaseFileName));
    final QueryExecutor executor =
        await _openWithRecovery(file, allowSidecarDelete: isMainProcess);
    return executor.interceptWith(_TypedOpenErrorInterceptor());
  });
}

/// Opens an arbitrary `.db` FILE (not a directory). Used by the backup MERGE
/// import (TODO-888) to migrate an extracted backup DB up to the current schema
/// before ATTACHing it to the live DB. Same robust open as [_openDb].
LazyDatabase _openDbFile(String dbFilePath, {bool isMainProcess = true}) {
  return LazyDatabase(() async {
    final file = File(dbFilePath);
    final QueryExecutor executor =
        await _openWithRecovery(file, allowSidecarDelete: isMainProcess);
    return executor.interceptWith(_TypedOpenErrorInterceptor());
  });
}

/// LWW-element-set 合并结果：[present]=名→加入戳（当前生效标签），[tombstones]=名→移除
/// 戳（移除胜出、需保留墓碑防复活的标签）。
class _MergedTagState {
  const _MergedTagState(this.present, this.tombstones);
  final Map<String, int> present;
  final Map<String, int> tombstones;
}

int _maxInt(int a, int b) => a > b ? a : b;

/// LWW-element-set 逐名裁决：并集两端 add 时钟与墓碑时钟，某标签名 max(addedAt) 严格
/// 大于 max(deletedAt) ⇒ present（否则 removed，含相等——remove-wins on tie，确定性）。
/// present 名清其墓碑（add 戳已持久，未来第三端旧移除仍会被 add 戳压过），removed 名保
/// 留墓碑防复活。
_MergedTagState _mergeTagClocks(
  Map<String, int> localAdded,
  Map<String, int> remoteAdded,
  Map<String, int> localTomb,
  Map<String, int> remoteTomb,
) {
  final Map<String, int> add = <String, int>{...localAdded};
  for (final MapEntry<String, int> e in remoteAdded.entries) {
    add[e.key] =
        add.containsKey(e.key) ? _maxInt(add[e.key]!, e.value) : e.value;
  }
  final Map<String, int> tomb = <String, int>{...localTomb};
  for (final MapEntry<String, int> e in remoteTomb.entries) {
    tomb[e.key] =
        tomb.containsKey(e.key) ? _maxInt(tomb[e.key]!, e.value) : e.value;
  }
  final Map<String, int> present = <String, int>{};
  final Map<String, int> tombstones = <String, int>{};
  for (final String name in <String>{...add.keys, ...tomb.keys}) {
    final int? a = add[name];
    final int? r = tomb[name];
    if (a != null && (r == null || a > r)) {
      present[name] = a;
    } else if (r != null) {
      tombstones[name] = r;
    }
  }
  return _MergedTagState(present, tombstones);
}

void _requireOneVideoMetadataOwner({
  int? workId,
  int? seasonId,
  int? episodeId,
  String? personKey,
  String? characterKey,
}) {
  final int count = <Object?>[
    workId,
    seasonId,
    episodeId,
    personKey,
    characterKey,
  ].where((Object? value) => value != null).length;
  if (count != 1) {
    throw ArgumentError('exactly one video metadata owner is required');
  }
}

@DriftDatabase(tables: [
  MediaOpenHistory,
  AnkiMappings,
  SearchHistoryItems,
  Audiobooks,
  AudioCues,
  SrtBooks,
  ReaderPositions,
  Bookmarks,
  ReadingStatistics,
  ReadingHourlyLogs,
  Preferences,
  DictionaryMetadata,
  DictionaryHistory,
  EpubBooks,
  BookTags,
  TagAssignments,
  Profiles,
  ProfileSettings,
  MediaTypeProfiles,
  BookProfiles,
  LanguageProfiles,
  SyncBaselines,
  VideoBooks,
  VideoWatchStatistics,
  VideoHourlyLogs,
  FavoriteWords,
  MiningStatistics,
  MinedSentences,
  MediaSources,
  Series,
  ShelfEntries,
  MediaCollections,
  MediaCollectionItems,
  CollectionMemberTombstones,
  CollectionBookAliases,
  FushiPairedPeers,
  BookTombstones,
  LookupMiningCounters,
  StatisticsTombstones,
  BookTagMembershipTombstones,
  BookCustomCss,
  MangaReaderOverrides,
  SyncDeletionTombstones,
  RevealedImages,
  ActivityEvents,
  ClipboardHistory,
  VideoScrapeMeta,
  CollectionScrapeMeta,
  MediaTrackingMappings,
  MediaTrackingOutbox,
  Galgames,
  GalgameSources,
  GalgameSessions,
  MangaExtensionStores,
  MangaExtensions,
  MangaOnlineSources,
  MangaSourcePreferences,
  MangaTrustedSigners,
  CollectionRelations,
  MediaImages,
  VideoMetadataWorks,
  VideoMetadataSeasons,
  VideoMetadataEpisodes,
  VideoMetadataPeople,
  VideoMetadataCharacters,
  VideoMetadataProviderIdentities,
  VideoMetadataRawSnapshots,
  VideoMetadataTerms,
  VideoMetadataWorkTerms,
  VideoMetadataCredits,
  VideoMetadataImages,
  VideoMetadataExtras,
  VideoSourceScrapeSettings,
  VideoSourceScrapeRuns,
  VideoSidecarArtifacts,
  VideoDownloadJobs,
  VideoDownloadJobFiles,
  VideoDownloadJobSubtitles,
  VideoDownloadSubscriptions,
  VideoDownloadSubscriptionItems,
  MangaChapterStates,
  StudySegmentTombstones,
  StudySegments,
  WebMineQueue,
  VideoFileSpecs,
  UpdateFeedEntries,
  MangaDownloadJobs,
  MangaChapterDirs,
  AnidbFileIdentities,
  VideoEpisodeBindingOverrides,
  PendingMineQueue,
  SrsEntities,
  SrsFieldEdits,
  SrsReviewLogs,
  SrsUnknownEvents,
  SrsEventLocal,
  SrsLocalState,
  SrsNotesCache,
  SrsCardsCache,
])
class FushiDatabase extends _$FushiDatabase
    with
        _FushiDbInfra,
        _FushiDbSrs,
        _FushiDbTagsSync,
        _FushiDbLibrary,
        _FushiDbPrefsMedia,
        _FushiDbContentMisc,
        _FushiDbStatistics,
        _FushiDbVideoDomain,
        _FushiDbUpdateFeed,
        _FushiDbMangaDownload {
  /// [isMainProcess] gates the TODO-905 sidecar rebuild: the main app passes
  /// the default `true` (it may physically delete a poisoned `-wal`/`-shm`),
  /// while the separate `:popup` process passes `false` so it backs off on an
  /// IOERR instead of racing the main process to delete the same sidecar.
  FushiDatabase(String dbDirectory, {bool isMainProcess = true})
      : _isMainProcess = isMainProcess,
        super(_openDb(dbDirectory, isMainProcess: isMainProcess));

  /// Opens a specific `.db` FILE (not a directory). Backup MERGE import
  /// (TODO-888) uses this to migrate an extracted backup DB to the current
  /// schema before merging it into the live DB.
  FushiDatabase.atFile(String dbFilePath, {bool isMainProcess = true})
      : _isMainProcess = isMainProcess,
        super(_openDbFile(dbFilePath, isMainProcess: isMainProcess));

  FushiDatabase.forTesting(super.e) : _isMainProcess = true;

  final bool _isMainProcess;

  @override
  int get schemaVersion => kMyComicSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await _createMyComicSchema(m);
        },
        onUpgrade: (m, from, to) async {
          // my-comic 不提供任何 Fushi v1-v118 的迁移路径；这里只维护 my-comic
          // 自己的小版本阶梯。
          // 比本构建更新的库（from > to）拒绝打开、绝不改库。
          if (from > to) {
            throw FushiDatabaseDowngradeException(
              dbVersion: from,
              appSchemaVersion: to,
            );
          }
          if (from == 1) {
            // v1 → 当前：Download library 的章节映射（票 04）。表定义按当前
            // 版本创建，因此 v3 起同时包含 `container_kind` 列。
            await m.createTable(mangaChapterDirs);
            // v4：v1 的 manga_download_jobs 仍带旧的 status CHECK，重建放宽。
            await m.alterTable(TableMigration(mangaDownloadJobs));
            // 重建表会连表上的索引一起删掉，按 _ensureIndexes 的约定补回。
            await _ensureIndexes();
            return;
          }
          if (from == 2) {
            // v2 → v3：章节映射增加显式容器类型（CBZ 票 06）。已有行都是
            // 章节目录；列默认值 `folder` 使它们无需数据回填。
            await m.addColumn(mangaChapterDirs, mangaChapterDirs.containerKind);
            // v4：下载任务表重建以放宽 status CHECK（新增 paused）。
            await m.alterTable(TableMigration(mangaDownloadJobs));
            await _ensureIndexes();
            return;
          }
          if (from == 3) {
            // v3 → v4：下载任务状态新增 `paused`（全局暂停，ticket 07）。
            // SQLite 不能原地改表级 CHECK；重建表并按同名列复制全部任务行。
            await m.alterTable(TableMigration(mangaDownloadJobs));
            await _ensureIndexes();
            return;
          }
          throw StateError(
            'Unsupported my-comic schema upgrade path: $from -> $to',
          );
        },
        beforeOpen: (details) async {
          // 降级保护：库文件由更新版本创建时拒绝打开，文件原样保留。
          final int? before = details.versionBefore;
          if (before != null && before > schemaVersion) {
            throw FushiDatabaseDowngradeException(
              dbVersion: before,
              appSchemaVersion: schemaVersion,
            );
          }
        },
      );

  /// 首次运行创建 my-comic 的漫画-only schema。
  ///
  /// 刻意**不用** `createAll()`（全量建表）：`@DriftDatabase` 里仍保留着历史表声明（供
  /// 尚未迁移的死代码编译），但 live schema 只允许 [kMyComicSchemaTableNames] 这些表。
  /// 创建顺序按 FK 依赖排列（profiles -> profile_settings、media_sources ->
  /// epub_books、series -> shelf_entries、media_collections -> collection_items）。
  Future<void> _createMyComicSchema(Migrator m) async {
    final List<TableInfo<Table, Object?>> tables = <TableInfo<Table, Object?>>[
      // 设备级偏好与 Profile
      preferences,
      profiles,
      profileSettings,
      mediaTypeProfiles,
      bookProfiles,
      languageProfiles,
      // Library / Local source / Category
      mediaSources,
      epubBooks,
      bookTags,
      tagAssignments,
      series,
      shelfEntries,
      mediaCollections,
      mediaCollectionItems,
      collectionMemberTombstones,
      collectionBookAliases,
      bookTombstones,
      bookTagMembershipTombstones,
      // History / Reading progress
      mediaOpenHistory,
      searchHistoryItems,
      readerPositions,
      revealedImages,
      activityEvents,
      studySegments,
      studySegmentTombstones,
      // Tracking
      mediaTrackingMappings,
      mediaTrackingOutbox,
      // Extension / Source / Updates
      mangaExtensionStores,
      mangaExtensions,
      mangaOnlineSources,
      mangaSourcePreferences,
      mangaTrustedSigners,
      updateFeedEntries,
      // Download / Reader
      mangaDownloadJobs,
      mangaChapterDirs,
      mangaChapterStates,
      mangaReaderOverrides,
      // 删除传播墓碑
      syncDeletionTombstones,
    ];
    for (final TableInfo<Table, Object?> table in tables) {
      await m.createTable(table);
    }
    // v81 的 uid 唯一索引不进 _ensureIndexes；fresh schema 在此补上漫画需要的部分。
    await customStatement(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_epub_books_uid '
        "ON epub_books (uid) WHERE uid != ''");
    await _ensureIndexes();
    await _ensureProfileUidIndex();
  }

  // ── 类级常量/静态键（被 `FushiDatabase.x` 形式跨库引用，extension 的
  // static 需 extension 名限定，故集中留在类体；方法本体在各 part）──

  /// TODO-855: persisted monotonic counter, bumped on every preference write
  /// at this single lowest-level write choke point ([setPref]). It is the
  /// cross-process change signal the separate :popup process reads (via a cheap
  /// indexed row lookup) to decide whether to reload its warm-reuse pref cache,
  /// instead of unconditionally re-scanning the whole preferences table on each
  /// lookup. Sinking the bump here means EVERY path that writes a preference —
  /// PreferencesRepository, ThemeNotifier (theme / app_ui_scale), MediaSource
  /// (per-source font sizes etc.), profile switch, sync/backup restore —
  /// automatically advances it; no caller can forget to bump.
  static const String prefsVersionKey = 'prefs_version';

  /// 合集级删除墓碑的哨兵值：mediaType 与 entryKey 皆为 ''（真实成员键恒非空，
  /// 无歧义）。
  static const String collectionTombstoneSentinel = '';

  /// 收藏词跨设备稳定身份键（= uniqueKey {expression, reading, sourceType} 的 NUL 连接串），
  /// 用作 `favoriteword` sync 删除墓碑的 itemKey。NUL 分隔符文本几乎不可能出现（同项目
  /// NUL 分组键约定），可逆解析见 app 层 `parseFavoriteWordItemKey`。
  static String favoriteWordItemKey(
          String expression, String reading, String sourceType) =>
      '$expression\u0000$reading\u0000$sourceType';

  /// 上限：保留最近 [kMinedSentenceHistoryLimit] 条制卡历史，避免无限增长。
  static const int kMinedSentenceHistoryLimit = 1000;

  /// sourceType 常量：与统计聚合 / lookup_mining_counters 的 source_type 同值。
  static const String statSourceBook = 'book';
  static const String statSourceVideo = 'video';

  /// 统计日分组键（本地时区 `yyyy-MM-dd`）的**唯一权威派生**（P4 写侧收敛 A 组）。
  /// app 层 `statDateKey` / 视频桶拆分等统计写入面的 dateKey 一律直接或间接走
  /// 这里，别再各自格式化一份。委托 [_FushiDbStatistics.statDateKeyOf]（复合
  /// 入口 recordReadingSession / recordMiningEvent 在 DB 层派生 dateKey 用的
  /// 同一实现）。
  static String statDateKeyOf(DateTime d) =>
      _FushiDbStatistics.statDateKeyOf(d);

  /// 「统计日」重置整点（0..23，默认 0）——「今日」从几点开始；见
  /// [_FushiDbStatistics.statDayResetHour]。偏好键 [kStatDayResetHourPrefKey]。
  static int get statDayResetHour => _FushiDbStatistics.statDayResetHour;
  static set statDayResetHour(int hour) =>
      _FushiDbStatistics.statDayResetHour = hour;

  /// 日历日 → `yyyy-MM-dd`（不看重置整点）。
  static String statCalendarDayKeyOf(DateTime day) =>
      _FushiDbStatistics.statCalendarDayKeyOf(day);

  /// dateKey → 对应日历日（本地午夜 DateTime，只用于日历算术）。
  static DateTime statDateKeyToDay(String dateKey) =>
      _FushiDbStatistics.statDateKeyToDay(dateKey);

  /// 键算术：[dateKey] 往后 [days] 天（负数往前）。窗口 / streak / 热力图一律走
  /// 这里，不要把合成的午夜 DateTime 喂给 [statDateKeyOf]。
  static String statDateKeyPlusDays(String dateKey, int days) =>
      _FushiDbStatistics.statDateKeyPlusDays(dateKey, days);

  /// 到下一个统计日边界（下一次 `statDayResetHour:00`）的时长，恒 > 0。
  static Duration untilNextStatDayBoundary(DateTime now) =>
      _FushiDbStatistics.untilNextStatDayBoundary(now);

  /// v92 学习事实段的幂等键生成（转发 [_FushiDbStatistics.newStudySegmentUid]；
  /// mixin 的 static 不经类继承，这里给调用方一个稳定入口）。
  static String newStudySegmentUid() => _FushiDbStatistics.newStudySegmentUid();

  /// 段 provenance 用的设备身份偏好键（与 fushi 层 SyncRepository 同一把 key）。
  static const String studyDeviceIdPrefKey =
      _FushiDbStatistics.studyDeviceIdPrefKey;
}

int _epubBookUidCounter = 0;

/// 书的本机稳定 uid 生成（v81 / P3 Stage 1）：`book_<微秒时刻>_<进程内计数>`。
/// 与迁移回填的 `book_<rowid>_<秒时刻>` 同命名空间不同后缀形，互不相撞；
/// 进程内计数器兜同微秒批量导入。**机器局域**身份，不进 wire（那边仍是
/// bookKey）；跨设备无需一致。
String generateEpubBookUid() => 'book_${DateTime.now().microsecondsSinceEpoch}_'
    '${_epubBookUidCounter++}';
