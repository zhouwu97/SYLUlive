import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Golden 测试的固定逻辑视口。
///
/// 测试内禁止散落 `tester.binding.setSurfaceSize(...)`，
/// 统一走 [setGoldenViewport] 并在测试结束后自动恢复默认 surface size。
abstract final class GoldenViewports {
  static const Size phone360x800 = Size(360, 800);
  static const Size phone390x844 = Size(390, 844);
}

/// 文本缩放档位。
///
/// [GoldenTextProfile.large] 对应 canonical viewport 的 large-text（1.3）。
/// 1.5 stress test 保留给高风险页面显式传入 `TextScaler.linear(1.5)`。
enum GoldenTextProfile {
  normal,
  large;

  TextScaler get scaler => switch (this) {
        GoldenTextProfile.normal => TextScaler.noScaling,
        GoldenTextProfile.large => const TextScaler.linear(1.3),
      };
}

/// 设置 Golden 视口，并在测试结束时恢复默认视图尺寸。
///
/// 使用 `tester.view.physicalSize`（现代 flutter_test API）设置逻辑尺寸：
/// `logicalSize × devicePixelRatio`。测试结束后自动 reset，禁止测试自行 cleanup。
Future<void> setGoldenViewport(WidgetTester tester, Size size) async {
  final view = tester.view;
  view.physicalSize = size * view.devicePixelRatio;
  addTearDown(() {
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });
}