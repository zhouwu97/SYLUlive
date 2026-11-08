import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('所有背景滤镜都经过原生淡入保护，避免独立渲染器再次遗漏', () {
    final calls = <String, int>{};
    final pattern = RegExp(r'\bBackdropFilter(?:\.\w+)?\s*\(');
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))) {
      final count = pattern.allMatches(file.readAsStringSync()).length;
      if (count != 0) {
        calls[file.path.replaceAll('\\', '/').replaceFirst('lib/', '')] = count;
      }
    }
    expect(calls, {'widgets/opacity_safe_backdrop_filter.dart': 1});
  });

  test('玻璃弹窗入口统一走表面过渡，避免新增整窗淡入遗漏', () {
    // 两个图片画布没有背景滤镜，保留原生图片预览动效。
    const nativeCalls = {
      'widgets/app_dialog.dart': 1,
      'screens/competition/competition_award_editor_screen.dart': 1,
      'screens/competition/competition_award_verification_admin_screen.dart': 1,
    };
    final calls = <String, int>{};
    final pattern = RegExp(r'\bshowDialog\s*(?:<[^>]+>)?\s*\(');
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))) {
      final count = pattern.allMatches(file.readAsStringSync()).length;
      if (count != 0) {
        calls[file.path.replaceAll('\\', '/').replaceFirst('lib/', '')] = count;
      }
    }
    expect(calls, nativeCalls,
        reason: '正文/确认弹窗使用 showAppDialog，不能把背景滤镜放进系统整窗 FadeTransition');
  });
}
