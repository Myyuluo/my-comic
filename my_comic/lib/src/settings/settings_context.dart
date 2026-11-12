import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_comic/src/media/sources/reader_my_comic_source.dart';
import 'package:my_comic/src/models/app_model.dart';
import 'package:my_comic/src/reader/reader_settings.dart';

class SettingsContext {
  const SettingsContext({
    required this.context,
    required this.appModel,
    required this.ref,
    required this.readerSource,
    required this.refresh,
  });

  final BuildContext context;
  final AppModel appModel;
  final WidgetRef ref;
  final ReaderMyComicSource readerSource;
  final VoidCallback refresh;

  ReaderSettings? get readerSettings => ReaderMyComicSource.readerSettings;
}

/// 设置宿主（State）统一构造 [SettingsContext] 的入口：readerSource 恒为单例、
/// refresh 恒为「mounted 时 setState」——四个宿主此前逐字重复这段样板。
/// [beforeRefresh] 在 setState 前执行额外联动（如阅读器面板主题行的
/// `_syncThemeSelection`）。
mixin SettingsContextHost<T extends StatefulWidget> on State<T> {
  SettingsContext createSettingsContext({
    required AppModel appModel,
    required WidgetRef ref,
    VoidCallback? beforeRefresh,
  }) {
    return SettingsContext(
      context: context,
      appModel: appModel,
      ref: ref,
      readerSource: ReaderMyComicSource.instance,
      refresh: () {
        if (!mounted) return;
        beforeRefresh?.call();
        setState(() {});
      },
    );
  }
}
