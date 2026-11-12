import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:my_comic_engine/media/manga/local_source/local_source_metadata.dart'
    show LocalSourceChapterRecord;

import 'package:my_comic/src/utils/misc/trimmed_text.dart';

/// 提供这条书架条目的在线漫画运行时。
///
/// 只用来在**重启后**把条目分派回正确的适配器，因此值必须稳定——它已经被写进
/// 用户库里的 `sourceMetadata` JSON。
enum OnlineMangaRuntimeKind {
  mihon('mihon'),

  /// 已移除的 Aidoku 运行时。宿主与源代码已整体删除，枚举值只为旧版本留下的
  /// 书架条目保留（wire 值已进用户库，冻结）；分派到
  /// `LegacyAidokuLibraryAdapter`，一律回报不可用。
  aidoku('aidoku'),

  /// 已配对的互联对端（把对端漫画库当成一个源，按页在线读）。
  ///
  /// 它没有「扩展包」，`extensionPackage` 恒是 [kInterconnectMangaPackage]、
  /// `sourceId` 恒是对端库那一维的常量，`seriesKey` = 对端 `bookKey`。
  interconnect('interconnect'),

  /// Local source（`local`）。**不是在线运行时**：没有 service/adapter，
  /// 只用于让作品页把本地章节列表交给共享的 `MangaChapterList` 渲染；条目本身
  /// 的持久化标记是 `LocalSourceMetadata`（`epub_books.sourceMetadata`），
  /// 不会把这个 wire 值写进库。
  local('local');

  const OnlineMangaRuntimeKind(this.wireValue);

  final String wireValue;

  static OnlineMangaRuntimeKind? fromWire(String? value) {
    for (final OnlineMangaRuntimeKind kind in OnlineMangaRuntimeKind.values) {
      if (kind.wireValue == value) return kind;
    }
    return null;
  }
}

/// 占位 extension package：备份里的 Source 尚未安装时，书架条目仍要有一个稳定
/// 身份，否则每次导入都会因为 package 不同而新建一行。
///
/// 运行时的数字 sourceId 回退（票 03）让安装扩展后无需改写这个占位值即可阅读。
/// 它也会被写进用户库，**永不可改**。
const String kUnavailableMihonExtensionPackage = 'mihon.unavailable';

/// 互联漫画源在书架身份里占的「扩展包」位。
///
/// 互联源没有扩展包，但 [OnlineMangaLibraryService.bookKeyFor] 的身份三元组
/// （包 / 源 / 作品）是**存量键推导**，不能为了这一个源改形状——那会让所有已入库的
/// 在线漫画变成找不到的孤儿。所以这里给一个固定占位值，让三元组保持原样。
///
/// ⚠️ 值已进用户库的 `epub_books.bookKey` 与磁盘目录名，**永不可改**。
const String kInterconnectMangaPackage = 'mycomic.interconnect';

/// 互联漫画源在书架身份里占的「源 id」位。
///
/// 恒定而不含对端地址：换 IP / 重新配对不该让书架条目全部失配（对端身份变化由
/// `InterconnectSyncBackend.sessionIdentityRevision` 驱动缓存失效，不由键表达）。
///
/// ⚠️ 同样已进 bookKey，**永不可改**。
const String kInterconnectMangaSourceId = 'library';

/// 在线漫画书架身份（`EpubBooks.bookKey`）的**唯一推导点**。
///
/// 身份三元组 `extensionPackage NUL sourceId NUL seriesKey` 的摘要既是主键也是
/// 磁盘目录名；Mihon 条目必须与 v88 前逐字节一致。抽成顶层函数是为了让不依赖
/// 运行时（[OnlineMangaLibraryService] 所在的重文件）的调用方——例如 Backup
/// Import——复用同一份推导，而不是各自抄一遍摘要算法。
String onlineMangaBookKeyFor({
  required OnlineMangaRuntimeKind runtime,
  required String extensionPackage,
  required String sourceId,
  required String seriesKey,
}) {
  final String identity = <String>[
    extensionPackage,
    sourceId,
    seriesKey,
  ].join(String.fromCharCode(0));
  final String digest = sha256.convert(utf8.encode(identity)).toString();
  return '${runtime.wireValue}-${digest.substring(0, 32)}';
}

/// 数字 sourceId 的规范形式；不是纯十进制数字时返回 null。
///
/// Mihon 的源 id 是 Long，以十进制字符串跨桥保存。导入占位条目和安装后的真实
/// Source 可能用不同字符串形式（如带前导零）表示同一个 id；来源解析与重复检测
/// 都必须按数字比较，而不是按字面比较。互联等非数字 sourceId 没有回退语义。
String? normalizedMangaSourceId(String sourceId) {
  final BigInt? value = BigInt.tryParse(sourceId.trim());
  return value?.toString();
}

/// 把 Local source 的章节表借成共享章节列表 / 章级状态用的条目形态。
///
/// [OnlineMangaRuntimeKind.local] 不是在线运行时：没有 service / adapter，也不
/// 会写进 `sourceMetadata`。作品页的展示条目与阅读器的章级上下文共用这一份
/// 转换，避免三处各抄一遍构造。
OnlineMangaLibraryEntry localSourceMangaLibraryEntry({
  required String seriesKey,
  required String title,
  required List<LocalSourceChapterRecord> chapters,
  int? currentChapterIndex,
}) => OnlineMangaLibraryEntry(
  runtime: OnlineMangaRuntimeKind.local,
  extensionPackage: '',
  sourceId: '',
  series: OnlineMangaSeries(
    key: seriesKey,
    title: title,
    raw: const <String, Object?>{},
  ),
  chapters: <OnlineMangaChapter>[
    for (final LocalSourceChapterRecord chapter in chapters)
      OnlineMangaChapter(
        key: chapter.key,
        name: chapter.name,
        raw: const <String, Object?>{},
      ),
  ],
  currentChapterIndex: currentChapterIndex,
);

/// 归一化后的章节。
///
/// [raw] 保留**运行时原生 payload**，因为翻页最终还是要把它交回
/// 运行时（如 `MihonRuntime.getPages`）。归一化只覆盖「展示 +
/// 身份」这几个字段：如果把 raw 丢掉换成完全结构化的模型，每加一个源就要
/// 在中间层补一次字段映射，而中间层根本不需要理解那些字段。
@immutable
class OnlineMangaChapter {
  const OnlineMangaChapter({
    required this.key,
    required this.name,
    required this.raw,
    this.scanlator,
    this.number,
    this.uploadedAt,
    this.sourceOrder,
    this.locked = false,
  });

  /// Mihon 扩展给锁定（未购买 / 未登录）章节的章名前缀约定。
  ///
  /// Mihon 的 `SChapter` 没有「锁」字段，keiyoushi 全家（BookWalker、Comikey、
  /// ebookjapan……）的做法是把这个 emoji 拼在章名开头、取页时抛
  /// `Log in via WebView ...`。这是宿主能拿到的**唯一**锁信号，所以判据只写在
  /// [isLockedChapterName] 这一处。コミコ（`Comico.LOCK = " 🔒"`）是拼在**结尾**
  /// 的，同样认（BUG-2514）。
  static const String mihonLockPrefix = '\u{1F512}';

  /// 章名带锁 emoji（开头或结尾）= 源站标记为锁定。
  static bool isLockedChapterName(String name) {
    final String trimmed = name.trim();
    return trimmed.startsWith(mihonLockPrefix) ||
        trimmed.endsWith(mihonLockPrefix);
  }

  /// 源内章节身份。Mihon = `url`；Aidoku = `chapter['key']`。
  ///
  /// 这是 `manga_chapter_states.chapter_key` 的取值，也是刷新章节列表后重新
  /// 定位「当前读到哪一章」的锚——索引会随源更新漂移，key 不会。
  final String key;
  final String name;
  final String? scanlator;
  final double? number;

  /// 上传时刻（毫秒）。0 或缺失记 null，避免 UI 把「未知」显示成 1970。
  final int? uploadedAt;

  /// 源列表里的位置，**0 = 最新一话**（Mihon `BackupChapter.sourceOrder`）。
  ///
  /// 阅读顺序按它降序（第 1 话 → 第 N 话）；null = 旧数据 / 本地源没有这个
  /// 信息，回退章节号与上传时间。在线源适配器按列表下标写入，导入时从备份
  /// 持久化。不要用它决定存储数组顺序：`chapters` 的数组顺序不是契约。
  final int? sourceOrder;

  /// 源站标记为锁定（要登录并购买 / 租借才能取页，BUG-2479）。
  ///
  /// Mihon 取自章名前缀约定（[isLockedChapterName]），Aidoku 取自章节 `locked`
  /// 字段。锁着的章入队下载必败，UI 据此在点击时引导登录、「下载全部」跳过它。
  final bool locked;

  /// 运行时原生 payload，原样回灌 `getPages`。
  final Map<String, Object?> raw;

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'name': name,
    if (scanlator != null) 'scanlator': scanlator,
    if (number != null) 'number': number,
    if (uploadedAt != null) 'uploadedAt': uploadedAt,
    if (sourceOrder != null) 'sourceOrder': sourceOrder,
    if (locked) 'locked': true,
    'raw': raw,
  };

  static OnlineMangaChapter? fromJson(Map<String, Object?> json) {
    final String key = json['key']?.toString() ?? '';
    if (key.isEmpty) return null;
    final Object? raw = json['raw'];
    final int? uploadedAt = (json['uploadedAt'] as num?)?.toInt();
    return OnlineMangaChapter(
      key: key,
      name: json['name']?.toString() ?? '',
      scanlator: json['scanlator']?.toString(),
      number: (json['number'] as num?)?.toDouble(),
      uploadedAt: uploadedAt == null || uploadedAt <= 0 ? null : uploadedAt,
      sourceOrder: (json['sourceOrder'] as num?)?.toInt(),
      locked: json['locked'] == true,
      raw: raw is Map<Object?, Object?>
          ? raw.cast<String, Object?>()
          : const <String, Object?>{},
    );
  }

  /// 从 v1 (`hibiki-mihon`) 描述符里的 `MihonChapter.toJson()` 升格。
  ///
  /// 老库里的章节没有独立 `key` 字段，身份就是 `url`；raw 直接沿用整个 map，
  /// 因为它本来就是 `MihonChapter.fromJson` 能吃的形状。
  static OnlineMangaChapter? fromLegacyMihonJson(Map<String, Object?> json) {
    final String url = json['url']?.toString() ?? '';
    if (url.isEmpty) return null;
    final int uploadedAt = (json['date_upload'] as num?)?.toInt() ?? 0;
    final String name = json['name']?.toString() ?? '';
    return OnlineMangaChapter(
      key: url,
      name: name,
      scanlator: json['scanlator']?.toString(),
      number: (json['chapter_number'] as num?)?.toDouble(),
      uploadedAt: uploadedAt <= 0 ? null : uploadedAt,
      locked: isLockedChapterName(name),
      raw: json,
    );
  }
}

/// 归一化后的作品。[raw] 同样保留运行时原生 payload。
@immutable
class OnlineMangaSeries {
  const OnlineMangaSeries({
    required this.key,
    required this.title,
    required this.raw,
    this.coverUrl,
    this.author,
    this.artist,
    this.description,
    this.genre,
  });

  /// 源内作品身份。Mihon = `url`；Aidoku = `manga['key']`。
  final String key;
  final String title;
  final String? coverUrl;
  final String? author;
  final String? artist;
  final String? description;

  /// 源给的原始体裁串（逗号分隔）；拆分交给 UI，因为不同源分隔符不一致。
  final String? genre;
  final Map<String, Object?> raw;

  List<String> get genreLabels {
    final String? value = genre;
    if (value == null || value.trim().isEmpty) return const <String>[];
    return value
        .split(RegExp(r'[,，、;；]'))
        .map((String item) => item.trim())
        .where((String item) => item.isNotEmpty)
        .toList(growable: false);
  }

  /// 作者优先、画师兜底——书架和卡片的副标题只有一行。
  String? get byline {
    final String? primary = author?.trim();
    if (primary != null && primary.isNotEmpty) return primary;
    final String? secondary = artist?.trim();
    if (secondary != null && secondary.isNotEmpty) return secondary;
    return null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'title': title,
    if (coverUrl != null) 'coverUrl': coverUrl,
    if (author != null) 'author': author,
    if (artist != null) 'artist': artist,
    if (description != null) 'description': description,
    if (genre != null) 'genre': genre,
    'raw': raw,
  };

  static OnlineMangaSeries? fromJson(Map<String, Object?> json) {
    final String key = json['key']?.toString() ?? '';
    if (key.isEmpty) return null;
    final Object? raw = json['raw'];
    return OnlineMangaSeries(
      key: key,
      title: json['title']?.toString() ?? '',
      coverUrl: json['coverUrl']?.toString(),
      author: json['author']?.toString(),
      artist: json['artist']?.toString(),
      description: json['description']?.toString(),
      genre: json['genre']?.toString(),
      raw: raw is Map<Object?, Object?>
          ? raw.cast<String, Object?>()
          : const <String, Object?>{},
    );
  }

  /// 从 v1 描述符里的 `MihonManga.toJson()` 升格。
  static OnlineMangaSeries? fromLegacyMihonJson(Map<String, Object?> json) {
    final String url = json['url']?.toString() ?? '';
    if (url.isEmpty) return null;
    return OnlineMangaSeries(
      key: url,
      title: json['title']?.toString() ?? '',
      coverUrl: (json['thumbnail_url'] ?? json['coverUrl'])?.toString(),
      author: json['author']?.toString(),
      artist: json['artist']?.toString(),
      description: json['description']?.toString(),
      genre: json['genre']?.toString(),
      raw: json,
    );
  }
}

/// 存进 [EpubBookRow.sourceMetadata] 的重启安全描述符（**不含**任何敏感信息）。
///
/// v88 前这里存的是 `MihonLibraryEntry`（`type: 'hibiki-mihon'`，硬绑
/// `MihonManga`/`MihonChapter`）。Aidoku 因此完全无法入库——它的作品/章节是无
/// 类型 map，塞不进那个形状。本类把描述符泛化成「运行时 + 归一化实体 + 原生
/// payload」，两个运行时共用同一条书架、同一个阅读器、同一份每章状态。
///
/// **向后兼容是硬约束**：[tryParse] 同时吃 v1 / v2 / v3。存量书架条目一行都不用改
/// 就能继续打开；它们会在下一次刷新章节列表时被顺带写成当前版本。
///
/// v3（设计稿 2026-09-12 §2.3）只在 v2 上加两个可选位 [subscribed] / [autoDownload]
/// （缺省 false），**不加 DB 列**。
///
/// 之后又以向后兼容的方式追加了可选 [sourceName]（导入时备份记录的来源名，
/// 缺省 null）：它同样只出现在 JSON 描述符里，不新增 DB 列；旧描述符没有该字段
/// 时照常解析为 null。
@immutable
class OnlineMangaLibraryEntry {
  const OnlineMangaLibraryEntry({
    required this.runtime,
    required this.extensionPackage,
    required this.sourceId,
    required this.series,
    required this.chapters,
    this.currentChapterIndex,
    this.subscribed = false,
    this.autoDownload = false,
    this.sourceName,
  });

  /// v1：只有 Mihon 的旧描述符。仍然解析，永不再写出。
  static const String legacyMihonMarker = 'hibiki-mihon';
  static const int legacyMihonVersion = 1;

  /// v2 / v3：运行时无关描述符（v3 = v2 + 订阅两位；同一解析器）。
  static const String marker = 'hibiki-online-manga';
  static const int version = 3;
  static const int previousVersion = 2;

  final OnlineMangaRuntimeKind runtime;

  /// Mihon = 扩展 `packageName`；Aidoku = 安装包 `id`。
  final String extensionPackage;

  /// Mihon = 源 id（十进制字符串，避免 JS 精度损失）；Aidoku = 包 id（单源包）。
  final String sourceId;

  final OnlineMangaSeries series;
  final List<OnlineMangaChapter> chapters;

  /// 最后一次**选中**的章节下标。
  ///
  /// 注意它表达的是「选择」不是「进度」：读到哪一页归 `manga_chapter_states`。
  /// 刷新章节列表后按 [OnlineMangaChapter.key] 重新定位，不靠下标。
  final int? currentChapterIndex;

  /// 追更：作品页书签图标。只是一个用户意图位，探针对每条在线条目都刷新。
  final bool subscribed;

  /// 新章自动入队下载（`runOnlineMangaUpdateProbe` 读它）。开订阅时默认同时开，
  /// 可在作品页菜单里单独关。
  final bool autoDownload;

  /// 备份里记录的 Source 显示名（可选）。
  ///
  /// 只在导入时 Source 尚未安装、条目落成 [kUnavailableMihonExtensionPackage]
  /// 占位身份时写入；来源安装后名称由 Source 表解析，这个字段只作为缺失来源的
  /// 友好降级文案（「来源未安装：<名称>」）。旧条目没有该字段，读取为 null。
  final String? sourceName;

  /// 条目仍以导入时写入的 [kUnavailableMihonExtensionPackage] 占位身份保存。
  ///
  /// 它表示「导入时 Source 未安装」，不是当前是否缺失的唯一判据——扩展安装后
  /// 运行时可按 sourceId 回退到真实 Source；反过来，已安装但停用的 Source 没有
  /// 这个标记也属于缺失来源。作品页用它决定是否用备份名称兜底，运行时可解析性
  /// 由来源解析结果单独判断。
  bool get hasUnavailableSourcePlaceholder =>
      runtime == OnlineMangaRuntimeKind.mihon &&
      extensionPackage == kUnavailableMihonExtensionPackage;

  OnlineMangaChapter? get currentChapter {
    final int? index = currentChapterIndex;
    if (index == null || index < 0 || index >= chapters.length) return null;
    return chapters[index];
  }

  int indexOfChapterKey(String key) =>
      chapters.indexWhere((OnlineMangaChapter item) => item.key == key);

  OnlineMangaLibraryEntry copyWith({
    OnlineMangaSeries? series,
    List<OnlineMangaChapter>? chapters,
    int? currentChapterIndex,
    bool clearCurrentChapter = false,
    bool? subscribed,
    bool? autoDownload,
    String? sourceName,
  }) => OnlineMangaLibraryEntry(
    runtime: runtime,
    extensionPackage: extensionPackage,
    sourceId: sourceId,
    series: series ?? this.series,
    chapters: chapters ?? this.chapters,
    currentChapterIndex: clearCurrentChapter
        ? null
        : currentChapterIndex ?? this.currentChapterIndex,
    subscribed: subscribed ?? this.subscribed,
    autoDownload: autoDownload ?? this.autoDownload,
    sourceName: sourceName ?? this.sourceName,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'type': marker,
    'version': version,
    'runtime': runtime.wireValue,
    'extensionPackage': extensionPackage,
    'sourceId': sourceId,
    'series': series.toJson(),
    'chapters': <Map<String, Object?>>[
      for (final OnlineMangaChapter chapter in chapters) chapter.toJson(),
    ],
    'currentChapterIndex': currentChapterIndex,
    'subscribed': subscribed,
    'autoDownload': autoDownload,
    if (sourceName != null) 'sourceName': sourceName,
  };

  String encode() => jsonEncode(toJson());

  static OnlineMangaLibraryEntry? tryParse(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(value);
      if (decoded is! Map<Object?, Object?>) return null;
      final Map<String, Object?> json = decoded.cast<String, Object?>();
      final String? type = json['type']?.toString();
      final int type2Version = (json['version'] as num?)?.toInt() ?? 0;
      if (type == marker &&
          (type2Version == version || type2Version == previousVersion)) {
        return _parseV2(json);
      }
      if (type == legacyMihonMarker && type2Version == legacyMihonVersion) {
        return _parseLegacyMihon(json);
      }
      return null;
    } on Object {
      // 描述符坏了只应该让这本书退化成「不是在线漫画」，不该让书架整页炸。
      return null;
    }
  }

  static OnlineMangaLibraryEntry? _parseV2(Map<String, Object?> json) {
    final OnlineMangaRuntimeKind? runtime = OnlineMangaRuntimeKind.fromWire(
      json['runtime']?.toString(),
    );
    final Object? rawSeries = json['series'];
    final Object? rawChapters = json['chapters'];
    if (runtime == null ||
        rawSeries is! Map<Object?, Object?> ||
        rawChapters is! List<Object?>) {
      return null;
    }
    final OnlineMangaSeries? series = OnlineMangaSeries.fromJson(
      rawSeries.cast<String, Object?>(),
    );
    if (series == null) return null;
    return OnlineMangaLibraryEntry(
      runtime: runtime,
      extensionPackage: json['extensionPackage']?.toString() ?? '',
      sourceId: json['sourceId']?.toString() ?? '',
      series: series,
      chapters: _chaptersFrom(rawChapters, OnlineMangaChapter.fromJson),
      currentChapterIndex: (json['currentChapterIndex'] as num?)?.toInt(),
      // v3 两位；v2 没有 → false。
      subscribed: json['subscribed'] == true,
      autoDownload: json['autoDownload'] == true,
      sourceName: trimmedOrNull(json['sourceName']),
    );
  }

  static OnlineMangaLibraryEntry? _parseLegacyMihon(Map<String, Object?> json) {
    final Object? rawManga = json['manga'];
    final Object? rawChapters = json['chapters'];
    if (rawManga is! Map<Object?, Object?> || rawChapters is! List<Object?>) {
      return null;
    }
    final OnlineMangaSeries? series = OnlineMangaSeries.fromLegacyMihonJson(
      rawManga.cast<String, Object?>(),
    );
    if (series == null) return null;
    return OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: json['extensionPackage']?.toString() ?? '',
      sourceId: json['sourceId']?.toString() ?? '',
      series: series,
      chapters: _chaptersFrom(
        rawChapters,
        OnlineMangaChapter.fromLegacyMihonJson,
      ),
      currentChapterIndex: (json['currentChapterIndex'] as num?)?.toInt(),
    );
  }

  static List<OnlineMangaChapter> _chaptersFrom(
    List<Object?> raw,
    OnlineMangaChapter? Function(Map<String, Object?>) parse,
  ) {
    final List<OnlineMangaChapter> chapters = <OnlineMangaChapter>[];
    for (final Object? item in raw) {
      if (item is! Map<Object?, Object?>) continue;
      final OnlineMangaChapter? chapter = parse(item.cast<String, Object?>());
      // 无 key 的章节丢掉而不是留空 key：空 key 会在 manga_chapter_states 里
      // 把所有坏章节挤进同一主键，互相覆盖已读状态。
      if (chapter != null) chapters.add(chapter);
    }
    return List<OnlineMangaChapter>.unmodifiable(chapters);
  }
}
