import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_platform.dart';
import 'platform_capabilities.dart';

/// 集中编排首帧后的平台初始化，防止 Android 服务在鸿蒙启动阶段被调用。
class PlatformBootstrap {
  PlatformBootstrap({PlatformCapabilities? capabilities})
      : _capabilities = capabilities ?? PlatformCapabilities.current;

  final PlatformCapabilities _capabilities;

  Future<void> initializeAfterFirstFrame({
    required FutureOr<void> Function() initializeAndroidServices,
  }) async {
    if (!_capabilities.supportsBackgroundReminder &&
        !_capabilities.supportsJPush) {
      debugPrint('跳过 ${_capabilities.platform.wireName} 的 Android 启动服务');
      return;
    }

    await initializeAndroidServices();
  }
}
