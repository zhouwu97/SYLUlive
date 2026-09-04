import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/theme/app_text_scaler.dart';

void main() {
  test('字体档位使用稳定存储值并对未知值回退到标准档', () {
    expect(
      AppFontSizePreset.fromStorage('small'),
      AppFontSizePreset.small,
    );
    expect(
      AppFontSizePreset.fromStorage('extra_large'),
      AppFontSizePreset.extraLarge,
    );
    expect(
      AppFontSizePreset.fromStorage('unexpected'),
      AppFontSizePreset.standard,
    );
    expect(
      AppFontSizePreset.fromStorage(null),
      AppFontSizePreset.standard,
    );
  });

  test('六个字体档位按约定倍率缩放文字', () {
    const baseFontSize = 20.0;

    expect(
      AppTextScaler(
        TextScaler.noScaling,
        AppFontSizePreset.small.scaleFactor,
      ).scale(baseFontSize),
      18,
    );
    expect(
      AppTextScaler(
        TextScaler.noScaling,
        AppFontSizePreset.slightlySmall.scaleFactor,
      ).scale(baseFontSize),
      19,
    );
    expect(
      AppTextScaler(
        TextScaler.noScaling,
        AppFontSizePreset.standard.scaleFactor,
      ).scale(baseFontSize),
      20,
    );
    expect(
      AppTextScaler(
        TextScaler.noScaling,
        AppFontSizePreset.large.scaleFactor,
      ).scale(baseFontSize),
      23,
    );
    expect(
      AppTextScaler(
        TextScaler.noScaling,
        AppFontSizePreset.largePlus.scaleFactor,
      ).scale(baseFontSize),
      24,
    );
    expect(
      AppTextScaler(
        TextScaler.noScaling,
        AppFontSizePreset.extraLarge.scaleFactor,
      ).scale(baseFontSize),
      26,
    );
  });

  test('应用倍率叠加在系统非线性缩放结果之上', () {
    const scaler = AppTextScaler(_PiecewiseTextScaler(), 1.15);

    expect(scaler.scale(10), closeTo(13.8, 0.0001));
    expect(scaler.scale(30), closeTo(51.75, 0.0001));
  });

  test('组合缩放器 clamp 限制最终倍率而不是系统倍率', () {
    const scaler = AppTextScaler(TextScaler.linear(1.5), 1.3);
    final clamped = scaler.clamp(
      minScaleFactor: 1.0,
      maxScaleFactor: 1.6,
    );

    expect(clamped.scale(10), closeTo(16, 0.0001));
  });

  test('系统缩放器和应用倍率相同时组合缩放器相等', () {
    expect(
      const AppTextScaler(TextScaler.linear(1.3), 1.15),
      const AppTextScaler(TextScaler.linear(1.3), 1.15),
    );
    expect(
      const AppTextScaler(TextScaler.linear(1.3), 1.15),
      isNot(const AppTextScaler(TextScaler.linear(1.3), 1.3)),
    );
  });
}

final class _PiecewiseTextScaler implements TextScaler {
  const _PiecewiseTextScaler();

  @override
  double scale(double fontSize) => fontSize * (fontSize <= 20 ? 1.2 : 1.5);

  @override
  double get textScaleFactor => 1.2;

  @override
  TextScaler clamp({
    double minScaleFactor = 0,
    double maxScaleFactor = double.infinity,
  }) {
    return this;
  }
}
