import 'package:flutter/foundation.dart';

/// 应用运行平台。
///
/// 构建脚本必须通过 `--dart-define=APP_PLATFORM=<platform>` 注入目标平台。
/// 未注入时保留 Flutter 的运行时判断，方便现有 Android、Web 和测试环境继续工作。
enum AppPlatform { android, ios, ohos, web, other }

extension AppPlatformX on AppPlatform {
  String get wireName => switch (this) {
        AppPlatform.android => 'android',
        AppPlatform.ios => 'ios',
        AppPlatform.ohos => 'ohos',
        AppPlatform.web => 'web',
        AppPlatform.other => 'other',
      };

  bool get isAndroid => this == AppPlatform.android;
  bool get isIOS => this == AppPlatform.ios;
  bool get isOhos => this == AppPlatform.ohos;
  bool get isWeb => this == AppPlatform.web;
}

/// 集中处理平台识别，业务页面不得直接散落使用 `Platform.isAndroid`。
class AppPlatforms {
  AppPlatforms._();

  static const String _configuredPlatform = String.fromEnvironment(
    'APP_PLATFORM',
  );

  @visibleForTesting
  static AppPlatform? currentOverrides;

  static AppPlatform get current {
    if (currentOverrides != null) return currentOverrides!;
    final configured = _fromWireName(_configuredPlatform);
    if (configured != null) return configured;
    if (kIsWeb) return AppPlatform.web;

    return switch (defaultTargetPlatform) {
      TargetPlatform.android => AppPlatform.android,
      TargetPlatform.iOS => AppPlatform.ios,
      // DevEco 直接构建未传入 dart-define 时，鸿蒙 Flutter 引擎会报告为
      // Fuchsia 平台；将其收敛到鸿蒙，避免误启用 Android 原生插件。
      TargetPlatform.fuchsia => AppPlatform.ohos,
      _ => AppPlatform.other,
    };
  }

  static AppPlatform? _fromWireName(String value) => switch (value) {
        'android' => AppPlatform.android,
        'ios' => AppPlatform.ios,
        'ohos' => AppPlatform.ohos,
        'web' => AppPlatform.web,
        'other' => AppPlatform.other,
        _ => null,
      };
}
