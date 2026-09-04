import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// 应用内可选的字体大小档位。
///
/// 持久化使用稳定字符串而不是倍率，后续即使微调倍率也无需迁移旧数据。
enum AppFontSizePreset {
  small(
    label: '较小',
    scaleFactor: 0.9,
    storageValue: 'small',
  ),
  standard(
    label: '标准',
    scaleFactor: 1.0,
    storageValue: 'standard',
  ),
  large(
    label: '较大',
    scaleFactor: 1.15,
    storageValue: 'large',
  ),
  extraLarge(
    label: '特大',
    scaleFactor: 1.3,
    storageValue: 'extra_large',
  );

  const AppFontSizePreset({
    required this.label,
    required this.scaleFactor,
    required this.storageValue,
  });

  final String label;
  final double scaleFactor;
  final String storageValue;

  static AppFontSizePreset fromStorage(String? value) {
    for (final preset in values) {
      if (preset.storageValue == value) return preset;
    }
    return standard;
  }
}

/// 在系统字体缩放结果之上叠加应用内倍率。
///
/// 这里保留系统 [TextScaler] 的完整缩放策略，不能先把它降级成单一倍率，
/// 否则 Android 的非线性无障碍字体缩放会失真。
@immutable
final class AppTextScaler implements TextScaler {
  const AppTextScaler(this.systemScaler, this.appScaleFactor)
      : assert(appScaleFactor > 0),
        assert(appScaleFactor < double.infinity);

  final TextScaler systemScaler;
  final double appScaleFactor;

  @override
  double scale(double fontSize) =>
      systemScaler.scale(fontSize) * appScaleFactor;

  @override
  double get textScaleFactor => scale(1.0);

  @override
  TextScaler clamp({
    double minScaleFactor = 0,
    double maxScaleFactor = double.infinity,
  }) {
    assert(maxScaleFactor >= minScaleFactor);
    assert(!maxScaleFactor.isNaN);
    assert(minScaleFactor.isFinite);
    assert(minScaleFactor >= 0);

    if (minScaleFactor == 0 && maxScaleFactor == double.infinity) {
      return this;
    }

    return AppTextScaler(
      systemScaler.clamp(
        minScaleFactor: minScaleFactor / appScaleFactor,
        maxScaleFactor: maxScaleFactor / appScaleFactor,
      ),
      appScaleFactor,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AppTextScaler &&
            systemScaler == other.systemScaler &&
            appScaleFactor == other.appScaleFactor;
  }

  @override
  int get hashCode => Object.hash(systemScaler, appScaleFactor);

  @override
  String toString() => '$systemScaler with app scale ${appScaleFactor}x';
}
