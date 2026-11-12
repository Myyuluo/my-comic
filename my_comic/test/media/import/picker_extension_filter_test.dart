// MyComic 只支持 Windows 桌面：文件选择器直接使用原生扩展名过滤，不再有移动端
// SAF / iOS security-scoped 分支。
//
// 这里是**行为测试**而不是源码扫描：把 `FilePicker.platform` 换成会记录入参的假
// 实现，真的走一遍公开原语，断言「传给平台的 type / allowedExtensions」与返回结果。

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/media/import/real_path_directory_picker.dart';
import 'package:my_comic/src/models/app_model.dart';
import 'package:path/path.dart' as p;

import '../../helpers/test_platform_services.dart';

/// 假 file_picker：记录平台**实际收到**的过滤参数，并交回指定的文件列表。
class _RecordingFilePicker extends FilePicker {
  _RecordingFilePicker(this.returnedPaths);

  /// 平台交回的文件路径（模拟用户在选择器里选中的东西）。
  final List<String> returnedPaths;

  FileType? lastType;
  List<String>? lastAllowedExtensions;
  bool? lastWithData;
  bool? lastAllowMultiple;
  int calls = 0;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    calls++;
    lastType = type;
    lastAllowedExtensions = allowedExtensions;
    lastWithData = withData;
    lastAllowMultiple = allowMultiple;
    return FilePickerResult(<PlatformFile>[
      for (final String path in returnedPaths)
        PlatformFile(name: p.basename(path), size: 0, path: path),
    ]);
  }
}

/// 拿一个真 [BuildContext] 跑 [body]。
Future<T> _withContext<T>(
  WidgetTester tester,
  Future<T> Function(BuildContext context) body,
) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (BuildContext context) {
          captured = context;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return body(captured);
}

/// 漫画导入真实可能用到的扩展名集。
const Set<String> kDictionaryExtensions = <String>{
  'zip',
  'dsl',
  'mdx',
  'ifo',
  'css',
};

/// 漫画/字幕相关扩展名集。
const Set<String> kSubtitleExtensions = <String>{'srt', 'vtt', 'ass', 'ssa'};

void main() {
  testWidgets('Windows：扩展名交给原生对话框过滤', (WidgetTester tester) async {
    final _RecordingFilePicker fake = _RecordingFilePicker(<String>[
      r'D:\dicts\a.mdx',
    ]);
    FilePicker.platform = fake;

    await _withContext(
      tester,
      (BuildContext context) => pickSystemFilePath(
        context: context,
        allowedExtensions: kDictionaryExtensions,
      ),
    );

    expect(
      fake.lastType,
      FileType.custom,
      reason: '桌面降级成 any 会让用户在一堆无关文件里翻找，属于无谓退化',
    );
    expect(fake.lastAllowedExtensions, containsAll(<String>['mdx', 'dsl']));
  });

  testWidgets('pickFilesByExtensions：原生过滤与 withData 原样透传', (
    WidgetTester tester,
  ) async {
    final _RecordingFilePicker fake = _RecordingFilePicker(<String>[
      '/dl/a.cbz',
    ]);
    FilePicker.platform = fake;

    final FilePickerResult? result = await _withContext(
      tester,
      (BuildContext context) => pickFilesByExtensions(
        context: context,
        allowedExtensions: <String>['cbz'],
        withData: true,
      ),
    );

    expect(fake.lastType, FileType.custom);
    expect(fake.lastWithData, isTrue, reason: 'withData 必须原样透传给平台');
    expect(result?.files.single.name, 'a.cbz');
  });

  testWidgets('空扩展名集 = 不过滤：直接 any', (WidgetTester tester) async {
    final _RecordingFilePicker fake = _RecordingFilePicker(<String>[
      r'D:\whatever.bin',
    ]);
    FilePicker.platform = fake;

    final FilePickerResult? result = await _withContext(
      tester,
      (BuildContext context) => pickFilesByExtensions(context: context),
    );

    expect(fake.lastType, FileType.any);
    expect(fake.lastAllowedExtensions, isNull);
    expect(result?.files.single.name, 'whatever.bin');
  });

  testWidgets('pickRealFilePathDetailed：Windows 出处恒为真实路径', (
    WidgetTester tester,
  ) async {
    final _RecordingFilePicker fake = _RecordingFilePicker(<String>[
      r'D:\manga\vol1.mokuro',
    ]);
    FilePicker.platform = fake;
    final AppModel model = AppModel(testPlatformServices());
    try {
      final PickedFilePath? picked = await _withContext(
        tester,
        (BuildContext context) => pickRealFilePathDetailed(
          context: context,
          appModel: model,
          allowedExtensions: <String>{'mokuro'},
        ),
      );
      expect(picked?.path, r'D:\manga\vol1.mokuro');
      expect(picked?.isRealPath, isTrue);
    } finally {
      model.dispose();
    }
  });
}
