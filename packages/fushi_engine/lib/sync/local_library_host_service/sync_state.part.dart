part of '../local_library_host_service.dart';

/// 同步状态域（B4 按域拆出）：Profile 传输、互联 service-config、活动流、聚合快照、合集清单、删除墓碑。
/// 方法逐字搬自 LocalLibraryHostService。
mixin _LocalLibraryHostSyncState
    on _LocalLibraryHostBase, _LocalLibraryHostShared {
  @override
  Future<bool> isInterconnectProfileTransferEnabled() async {
    // 三者缺一即视为不可用：没有导出/导入回调时开着开关也无从服务。
    final Future<bool> Function()? enabled = _isProfileTransferEnabled;
    if (enabled == null) return false;
    if (_exportActiveProfileJson == null || _importProfileJson == null) {
      return false;
    }
    return enabled();
  }

  /// 导出**也**要串行：激活 Profile 的导出会先 `snapshotCurrentSettings()`，
  /// 那是一次写库 —— 一个远端 GET 就能和正在跑的备份恢复 / 集合同步交错。
  @override
  Future<String> exportInterconnectProfile() async {
    final Future<String> Function()? export = _exportActiveProfileJson;
    if (export == null) {
      throw UnsupportedError('profile export not wired on this host');
    }
    late final String json;
    await _runExclusive(() async {
      json = await export();
    });
    return json;
  }

  /// 导入必须串行：底下的 `importProfileFromJson` 是跨三个 await 的
  /// check-then-act（算唯一名 → 建 Profile → 写设置）。两个并发对端（或一个对端
  /// 重试）会算出**同一个名字**，而且在建行与写设置之间存在一个「有名字、零设置」
  /// 的半成品 Profile 对本机 UI 可见。client 侧的 `_busy` 只挡本机重复点击，挡不
  /// 住并发对端 —— 串行锁得由 host 侧兜。
  @override
  Future<String> importInterconnectProfile(String json) async {
    final Future<String> Function(String json)? import = _importProfileJson;
    if (import == null) {
      throw UnsupportedError('profile import not wired on this host');
    }
    late final String name;
    await _runExclusive(() async {
      name = await import(json);
    });
    return name;
  }

  @override
  Future<InterconnectServiceConfigSnapshot>
      getInterconnectServiceConfig() async {
    return InterconnectServiceConfigSnapshot.fromPreferences(
      await _db.getAllPrefs(),
    );
  }

  /// host 最近 [limit] 条活动事件（新首页 Activity 面板互联数据源）。
  @override
  Future<List<RemoteActivityEvent>> listActivityEvents(
      {int limit = 100}) async {
    // v92：活动流唯一数据源是统一事实面（legacy 活动行 ∪ 段 ∪ 游玩会话合成行），
    // 与本机首页同一份；否则 client 看不到 host 在 v92 之后的任何阅读 / 观看。
    final List<ActivityEventRow> rows =
        (await loadStatFacts(_db, activityLimit: limit)).activityRows;
    return <RemoteActivityEvent>[
      for (final ActivityEventRow r in rows)
        RemoteActivityEvent(
          eventType: r.eventType,
          mediaType: r.mediaType,
          title: r.title,
          dateKey: r.dateKey,
          timestampMs: r.timestampMs,
          mediaKey: r.mediaKey,
          durationMs: r.durationMs,
          charsDelta: r.charsDelta,
        ),
    ];
  }

  // ── 聚合（统计 + 收藏，TODO-1056 phase C）────────────────────────────────────

  /// 读 host 端当前聚合快照。直接复用云后端 phase B 的
  /// [AggregateSyncService.materializeLocalSnapshot]（同一 DB 读取逻辑），保证互联
  /// 与云通道 materialize 结果字节等价、无第二套实现。
  @override
  Future<AggregateSnapshot> getAggregateSnapshot() async {
    return AggregateSyncService(_db).materializeLocalSnapshot();
  }

  /// 把 client 上报的聚合快照折叠进 host DB。用
  /// [AggregateSyncService.foldIntoLocal]（先 materialize host 自己 → MAX / 并集
  /// 合并 incoming → apply），保证 host 侧也满足 never-shrinks：client 上报的某字段
  /// 即便小于 host 当前值（并发 / GET 后 host 又涨），MAX 折叠让 host 值不被缩小；
  /// 幂等（重复 apply 同一快照不变）；删除不跨端传播。经 [_runSyncStateExclusive]
  /// 与本机出站同步的聚合落库串行，避免读-改-写交错丢更新；**不**排在 host 自己的
  /// 整轮同步后面（BUG-2717：否则对端 PUT 15s 拿不到响应头即超时）。
  @override
  Future<void> applyAggregateSnapshot(AggregateSnapshot snapshot) async {
    await _runSyncStateExclusive(
      () => AggregateSyncService(_db).foldIntoLocal(snapshot),
    );
  }

  // ── 标签清单（互联标签同步，tag_sync.dart）────────────────────────────────

  @override
  Future<TagManifest> getTagManifest() => loadLocalTagManifest(_db);

  /// 把 client 上报的标签清单按 LWW 并入 host DB，返回并入后的 host 清单。按名
  /// 合并与顺序无关、重放幂等，所以不需要合集那样的因果基线；与本机出站同步的
  /// 标签落库经 [_runSyncStateExclusive] 串行，避免读-改-写交错。
  @override
  Future<TagManifest> mergeTagManifest(TagManifest incoming) async {
    late TagManifest merged;
    await _runSyncStateExclusive(() async {
      await applyTagManifest(_db, incoming);
      merged = await loadLocalTagManifest(_db);
    });
    return merged;
  }

  @override
  Future<List<({String mediaType, String itemKey, int deletedAt})>>
      listDeletionTombstones() async {
    final List<SyncDeletionTombstoneRow> rows =
        await _db.getSyncDeletionTombstones();
    return <({String mediaType, String itemKey, int deletedAt})>[
      for (final SyncDeletionTombstoneRow r in rows)
        (mediaType: r.mediaType, itemKey: r.itemKey, deletedAt: r.deletedAt),
    ];
  }
}
