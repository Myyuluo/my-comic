import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/utils/misc/platform_utils.dart';

/// BUG-1546：视频页内设置侧栏此前硬编码 560 固定宽，桌面大窗口下挤成窄条。
/// [myComicQuickSettingsPanelWidth] 按窗口宽度取半、clamp 到 560..900：
/// 窄窗保住旧值（零回退）、大窗口自适应放宽、上限与快捷设置弹窗同源。
void main() {
  test('窄窗（≤1120）保持旧固定值 560，行为零变化', () {
    expect(myComicQuickSettingsPanelWidth(400), kMyComicSettingsWideThreshold);
    expect(myComicQuickSettingsPanelWidth(800), kMyComicSettingsWideThreshold);
    expect(myComicQuickSettingsPanelWidth(1120), kMyComicSettingsWideThreshold);
  });

  test('大窗口随宽度取半放宽，1800 起封顶 900（与设置弹窗上限同源）', () {
    expect(myComicQuickSettingsPanelWidth(1440), 720);
    expect(myComicQuickSettingsPanelWidth(1800), kMyComicSettingsDialogMaxWidth);
    expect(myComicQuickSettingsPanelWidth(3840), kMyComicSettingsDialogMaxWidth);
  });

  test('无界宽度回退旧固定值（防御性下界）', () {
    expect(
      myComicQuickSettingsPanelWidth(double.infinity),
      kMyComicSettingsWideThreshold,
    );
  });

  test('BUG-1546 源码守卫：视频设置侧栏宽度必须走自适应函数，不得回退硬编码 560', () {
    final String source = File(
      'lib/src/pages/implementations/video_my_comic/side_panel.part.dart',
    ).readAsStringSync();
    final RegExp settingsCase = RegExp(
      r'case _VideoSidePanelKind\.settings:[\s\S]{0,800}?'
      r'return myComicQuickSettingsPanelWidth\(',
    );
    expect(
      settingsCase.hasMatch(source),
      isTrue,
      reason:
          '设置侧栏宽度（_videoSidePanelWidth 的 settings 分支）必须调用 '
          'myComicQuickSettingsPanelWidth 自适应，不允许回退固定 560 窄条',
    );
  });
}
