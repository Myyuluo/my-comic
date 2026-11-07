import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';

/// 设置 →「存储与下载」的「导入本地漫画」小节（storage-layout spec / ADR 0013）。
///
/// 只做用户显式触发的一次扫描：读当前 Content root 的 `localcomic`，把第一层
/// 作品目录登记进 Library。原地读取、不复制、不移动文件；主动移出书架的作品由
/// tombstone 跳过。视觉复用现有设置行与 toast（ADR 0008）。
SettingsSection buildLocalComicsImportSection() {
  return SettingsSection(
    id: 'storage.local_import.section',
    presentation: SettingsSectionPresentation.alwaysExpanded,
    title: t.data_storage_import_local_comics_section,
    visible: (SettingsContext ctx) => isDesktopPlatform,
    items: <SettingsItem>[
      SettingsStatusItem(
        id: 'storage.import_local_comics',
        title: t.data_storage_import_local_comics_title,
        subtitle: t.data_storage_import_local_comics_subtitle,
        icon: FushiIcons.folderOpen,
        actionLabel: t.data_storage_import_local_comics_button,
        onAction: _importLocalComics,
      ),
    ],
  );
}

/// 扫描 `localcomic` 并报告新增/刷新/墓碑跳过/失败的数量。
Future<void> _importLocalComics(SettingsContext settings) async {
  try {
    final LocalSourceImportReport report = await LocalSourceLibrary(
      db: settings.appModel.database,
      root: settings.appModel.appPaths.localComicRoot,
    ).importFromRoot();
    if (!settings.context.mounted) return;
    FushiToast.show(
      msg: t.manga_import_batch_done(
        imported: report.added + report.refreshed,
        skipped: report.skippedTombstoned,
        failed: report.failed,
      ),
      severity: report.failed > 0
          ? ToastSeverity.warning
          : ToastSeverity.success,
    );
  } on Object catch (error) {
    if (!settings.context.mounted) return;
    FushiToast.show(
      msg: t.data_storage_import_local_comics_failed(message: '$error'),
      severity: ToastSeverity.error,
    );
  }
}
