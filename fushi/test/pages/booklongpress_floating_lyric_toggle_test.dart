import 'package:flutter_test/flutter_test.dart';
import 'reader_history_source_corpus.dart';

/// 守卫（TODO-160子d / BUG-227 / TODO-291 阶段2）：书架长按 EPUB 书籍菜单的 extraActions
/// 含悬浮字幕入口。TODO-291 阶段2 把该入口从「只切 setShowFloatingLyric 偏好」升级为
/// 「启动该书的后台听书会话」（无正在播用该书启动 + 拉悬浮窗；该书已是活动会话则停止），
/// 走 AppModel.startBackgroundListening / stopBackgroundListening。host 跑不到 dialog
/// 渲染与 Platform 分支，故源码扫描钉接线。
void main() {
  late String src;
  setUpAll(() {
    src = readReaderHistorySource();
  });

  test('extraActions 含悬浮字幕开关 label', () {
    expect(
      src.contains('floating_lyric_toggle_action'),
      isTrue,
      reason: '长按书籍菜单必须有悬浮字幕开关入口。',
    );
  });

  test('书架入口启动/停止后台听书会话（TODO-291 阶段2）', () {
    expect(
      src.contains('_toggleFloatingLyricFromShelf'),
      isTrue,
      reason: '书架入口走专用切换方法。',
    );
    expect(
      src.contains('startBackgroundListening'),
      isTrue,
      reason: '书架入口必须启动该书的后台听书会话（不再只切偏好）。',
    );
    expect(
      src.contains('stopBackgroundListening'),
      isTrue,
      reason: '该书已是活动会话时入口必须能停止后台听书。',
    );
  });

  test('入口门控 Android/Windows（与 isSupported 一致，不删现有入口）', () {
    expect(
      src.contains('Platform.isAndroid || Platform.isWindows'),
      isTrue,
      reason: '悬浮字幕仅 Android/Windows 支持。',
    );
  });

  test('书籍长按菜单含「标签」项（统一三库页卡菜单）并保留其它管理动作', () {
    final String epubActions = _sectionSource(
      src,
      'List<DialogAction> extraActions(MediaItem item) {',
      '  String? _parseBookKey(String mediaIdentifier) =>',
    );
    final String srtActions = _sectionSource(
      src,
      'List<DialogAction> _srtExtraActions(',
      '  Future<void> _showSrtBookDialog(',
    );

    // 用户 2026-07-28 拍板正式推翻 TODO-455：书卡与视频/游戏卡对称含「标签」
    // 项（此前书打标签只有拖标签/批量两条路径，与另两库页不一致）。两侧走
    // 共享标签池 TagPickerPage（媒体路，MediaRef 身份）。
    for (final String actions in <String>[epubActions, srtActions]) {
      expect(
        actions,
        contains('t.tag_label'),
        reason: '统一三库页卡菜单：书卡与视频/游戏卡对称含「标签」项'
            '（用户 2026-07-28 拍板推翻 TODO-455）。',
      );
      expect(actions, contains('Icons.sell_outlined'));
      expect(
        actions,
        contains('_openMediaTagPicker'),
        reason: '书卡「标签」走共享 TagPickerPage 入口。',
      );
    }
    expect(epubActions, contains('kind: MediaKind.epub'));
    expect(srtActions, contains('kind: MediaKind.srt'));

    // 统一三库页刮削入口：书卡菜单直挂「在线刮削封面」（不再必须绕编辑信息弹窗）。
    expect(
      epubActions,
      contains('t.book_scrape_cover'),
      reason: '书卡菜单必须直挂「在线刮削封面」（统一刮削入口层级）。',
    );

    // 2026-11-05：查看插画 / 指定配置 / 编辑书籍 CSS 入口已从漫画页菜单移除
    // （my-comic 不需要）；有声书导入与悬浮字幕仍按模块门控保留。
    expect(epubActions, isNot(contains('t.view_illustrations')));
    expect(epubActions, contains('t.audiobook_import'));
    expect(epubActions, isNot(contains('t.profile_book_profile')));
    expect(epubActions, isNot(contains('t.book_css_editor_edit_css')));
    expect(epubActions, contains('floating_lyric_toggle_action'));

    // TODO-1191：SRT 卡长按菜单不再列冗余的「选择封面图片」——选封面统一走
    // 「编辑信息」弹窗（MediaItemEditDialogPage 的封面覆盖字段）。
    expect(
      srtActions,
      isNot(contains('t.srt_import_pick_cover')),
      reason: 'TODO-1191：SRT 卡长按菜单移除冗余「选择封面图片」，走编辑信息弹窗。',
    );
    // 「导入音频」已扩成「重新导入」（音频 + 字幕两半，见 SrtBookReimportDialog）：
    // 旧入口只能换音频，字幕书的字幕在首次导入后全仓无处可换。
    expect(srtActions, contains('t.srt_book_reimport'));
    expect(srtActions, isNot(contains('t.profile_book_profile')));
    expect(srtActions, isNot(contains('t.book_css_editor_edit_css')));
    // TODO-1068：SRT/有声书卡长按菜单对称补悬浮字幕入口，与 EPUB 侧一致。
    expect(
      srtActions,
      contains('floating_lyric_toggle_action'),
      reason: 'SRT/有声书卡长按菜单也必须有悬浮字幕入口（TODO-1068）。',
    );
    expect(
      srtActions,
      contains('_toggleFloatingLyricFromShelf'),
      reason: 'SRT 卡悬浮字幕入口复用 EPUB 侧同一后台听书切换回调。',
    );
    expect(
      srtActions,
      contains('Platform.isAndroid || Platform.isWindows'),
      reason: 'SRT 卡悬浮字幕入口平台门控与 EPUB 侧一致。',
    );
  });

  test('单卡长按菜单不再含「加入合集」入口', () {
    final String epubActions = _sectionSource(
      src,
      'List<DialogAction> extraActions(MediaItem item) {',
      '  String? _parseBookKey(String mediaIdentifier) =>',
    );
    final String srtActions = _sectionSource(
      src,
      'List<DialogAction> _srtExtraActions(',
      '  Future<void> _showSrtBookDialog(',
    );
    // 2026-11-05：漫画页不再提供合集功能；合集本身的删除见 ticket 21。
    expect(epubActions, isNot(contains('t.add_to_collection')));
    expect(srtActions, isNot(contains('t.add_to_collection')));
    expect(epubActions, isNot(contains('showAddToCollectionDialog')));
    expect(srtActions, isNot(contains('showAddToCollectionDialog')));
  });

  test('SRT 卡长按菜单不再含「查看插画」入口', () {
    final String srtActions = _sectionSource(
      src,
      'List<DialogAction> _srtExtraActions(',
      '  Future<void> _showSrtBookDialog(',
    );
    expect(srtActions, isNot(contains('t.view_illustrations')));
    expect(srtActions, isNot(contains('_openIllustrations')));
    expect(
      srtActions,
      isNot(contains('t.srt_import_pick_cover')),
      reason: 'TODO-1191：SRT 卡长按菜单移除冗余「选择封面图片」。',
    );
  });

  test('SRT 卡封面尊重编辑信息弹窗写入的 override thumbnail（TODO-1191）', () {
    // 移除外层「选择封面图片」后，选封面唯一入口是编辑信息弹窗，它经
    // MediaSource.setOverrideThumbnailFromMediaItem 写 override thumbnail 文件。
    // 因此 SRT 卡封面渲染必须优先读该 override（否则编辑信息里选的封面不生效）。
    final String srtCover = _sectionSource(
      src,
      'Widget _buildSrtCover(SrtBook book',
      '  MediaItem _srtBookMediaItem(SrtBook book) {',
    );
    // BUG-1317 起读取入口改为 resolveOverrideThumbnailFile——它在规范文件名之外
    // 还认得存量的旧文件名（源键烧进 hash）并就地迁移；裸
    // getOverrideThumbnailFilename 会把未迁移的封面判成「没有」。
    expect(
      srtCover,
      contains('resolveOverrideThumbnailFile'),
      reason: 'SRT 卡封面必须优先读编辑信息弹窗写入的 override thumbnail（TODO-1191），'
          '且必须走迁移感知入口（BUG-1317）。',
    );
    // 仍保留 book.coverPath 回退，向后兼容历史外层「选择封面图片」写入的封面。
    expect(
      srtCover,
      contains('book.coverPath'),
      reason: '无 override 时仍回退历史 book.coverPath（向后兼容）。',
    );
  });

  test('书籍长按对话框隐藏阅读按钮，点击卡片仍负责阅读', () {
    final String srtDialog = _sectionSource(
      src,
      'Future<void> _showSrtBookDialog(SrtBook book)',
      '  bool _srtBookHasMissingAudio(',
    );
    // BUG-2969：EPUB / 漫画 / PDF 书卡的长按对话框抽成 _showEpubItemMenu（书架卡与
    // 合集详情成员卡同一入口），书卡的 onLongPress 只转发到它。
    final String epubCard = _sectionSource(
      src,
      'Widget _buildEpubBookCard(MediaItem item,',
      '      child: buildMediaItemContent(item),',
    );
    expect(epubCard, contains('onLongPress: () => _showEpubItemMenu(item),'));
    final String epubDialog = _sectionSource(
      src,
      'Future<void> _showEpubItemMenu(',
      '    if (isHistory && mounted) {',
    );

    expect(srtDialog, contains('showLaunchAction: false'));
    expect(epubDialog, contains('showLaunchAction: false'));
    expect(src, contains('onTap: () async {'));
    expect(src, contains('await appModel.openMedia('));
  });
}

String _sectionSource(String source, String startToken, String endToken) {
  final int start = source.indexOf(startToken);
  final int end = source.indexOf(endToken, start + startToken.length);
  expect(start, isNonNegative, reason: 'Missing source marker: $startToken');
  expect(end, greaterThan(start),
      reason: 'Missing end marker after $startToken: $endToken');
  return source.substring(start, end);
}
