import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/media.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/audiobook/book_import_dialog.dart';
import 'package:fushi/src/media/import/quick_import_section.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:material_ui/material_ui.dart';

/// 书籍库「导入」视图：EPUB / PDF / 文本 / 字幕 / 有声书的单件导入入口。
///
/// 来源库扫描根已随非漫画域移除，本页只保留快速导入。
class BookSourcesPage extends ConsumerStatefulWidget {
  const BookSourcesPage({super.key, this.navigation});

  /// 库页视图导航条（由 MediaLibraryShell 传入）。
  final Widget? navigation;

  @override
  ConsumerState<BookSourcesPage> createState() => _BookSourcesPageState();
}

class _BookSourcesPageState extends ConsumerState<BookSourcesPage> {
  late final AppModel _appModel = ref.read(appProvider);

  Future<void> _importBookFile() async {
    final bool? imported = await showAppDialog<bool>(
      context: context,
      builder: (_) => BookImportDialog(
        prefs: _appModel.prefsRepo,
        repo: SrtBookRepository(_appModel.database),
        audiobookRepo: AudiobookRepository(_appModel.database),
        db: _appModel.database,
      ),
    );
    if (imported != true || !mounted) return;
    ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    ref.invalidate(srtBooksProvider);
  }

  Widget _buildHeader() {
    final Widget? navigation = widget.navigation;
    if (navigation != null) {
      return FushiPageHeader.customTitle(
        title: navigation,
        actions: const <Widget>[],
      );
    }
    return FushiPageHeader(
      title: t.library_view_import,
      actions: const <Widget>[],
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!isCupertinoPlatform(context)) _buildHeader(),
          Expanded(
            child: FushiEntranceScope(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  tokens.spacing.page,
                  FushiFloatingChromeInset.of(context) + tokens.spacing.gap,
                  tokens.spacing.page,
                  tokens.spacing.page,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    QuickImportSection(
                      heroIcon: FushiIcons.books,
                      formats: const <String>[
                        'EPUB',
                        'PDF',
                        'TXT',
                        'SRT',
                        'ASS',
                        'MP3',
                        'M4B',
                      ],
                      actions: <QuickImportAction>[
                        QuickImportAction(
                          icon: FushiIcons.importFile,
                          label: t.srt_import,
                          onTap: _importBookFile,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
