import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/app_platform.dart';
import 'diagnostic_log_service.dart';

class KeepAliveStatus {
  final bool supported;
  final bool enabled;
  final bool serviceRunning;
  final bool hideRecentsEnabled;
  final String manufacturer;
  final int sdkInt;
  final bool isIgnoringBatteryOptimizations;
  final String state;

  const KeepAliveStatus({
    required this.supported,
    required this.enabled,
    required this.serviceRunning,
    required this.hideRecentsEnabled,
    required this.manufacturer,
    required this.sdkInt,
    required this.isIgnoringBatteryOptimizations,
    this.state = 'unknown',
  });

  const KeepAliveStatus.unsupported()
      : supported = false,
        enabled = false,
        serviceRunning = false,
        hideRecentsEnabled = false,
        manufacturer = '',
        sdkInt = 0,
        isIgnoringBatteryOptimizations = true,
        state = 'unsupported';

  const KeepAliveStatus.bridgeError()
      : supported = false,
        enabled = false,
        serviceRunning = false,
        hideRecentsEnabled = false,
        manufacturer = '',
        sdkInt = 0,
        isIgnoringBatteryOptimizations = true,
        state = 'native_error';

  factory KeepAliveStatus.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) return const KeepAliveStatus.unsupported();
    final supported = map['supported'] == true;
    final enabled = map['enabled'] == true;
    final serviceRunning = map['serviceRunning'] == true;
    final ignoringBattery = map['isIgnoringBatteryOptimizations'] != false;
    final state = map['state']?.toString().trim();
    return KeepAliveStatus(
      supported: supported,
      enabled: enabled,
      serviceRunning: serviceRunning,
      hideRecentsEnabled: map['hideRecentsEnabled'] == true,
      manufacturer: map['manufacturer']?.toString() ?? '',
      sdkInt: (map['sdkInt'] as num?)?.toInt() ?? 0,
      isIgnoringBatteryOptimizations: ignoringBattery,
      state: state?.isNotEmpty == true
          ? state!
          : !supported
              ? 'unsupported'
              : !enabled
                  ? 'disabled'
                  : !ignoringBattery
                      ? 'permission_missing'
                      : !serviceRunning
                          ? 'enabled_not_running'
                          : 'ready',
    );
  }
}

class KeepAliveService {
  KeepAliveService._();

  static final KeepAliveService instance = KeepAliveService._();
  static const MethodChannel _channel = MethodChannel('shenliyuan/keep_alive');

  /// 使用构建目标而非 Flutter 运行时平台；OHOS Flutter 当前会报告 Android。
  bool get _isAndroid => AppPlatforms.current.isAndroid;

  Future<KeepAliveStatus> status() async {
    if (!_isAndroid) return const KeepAliveStatus.unsupported();
    try {
      final result = await _channel.invokeMapMethod<dynamic, dynamic>(
        'getKeepAliveStatus',
      );
      return KeepAliveStatus.fromMap(result);
    } catch (error, stackTrace) {
      _recordBridgeError('getKeepAliveStatus', error, stackTrace);
      return const KeepAliveStatus.bridgeError();
    }
  }

  Future<KeepAliveStatus> setEnabled(bool enabled) async {
    if (!_isAndroid) return const KeepAliveStatus.unsupported();
    try {
      final result = await _channel.invokeMapMethod<dynamic, dynamic>(
        'setKeepAliveEnabled',
        {'enabled': enabled},
      );
      return KeepAliveStatus.fromMap(result);
    } catch (error, stackTrace) {
      _recordBridgeError('setKeepAliveEnabled', error, stackTrace);
      return const KeepAliveStatus.bridgeError();
    }
  }

  Future<KeepAliveStatus> setHideRecentsEnabled(bool enabled) async {
    if (!_isAndroid) return const KeepAliveStatus.unsupported();
    try {
      final result = await _channel.invokeMapMethod<dynamic, dynamic>(
        'setHideRecentsEnabled',
        {'enabled': enabled},
      );
      return KeepAliveStatus.fromMap(result);
    } catch (error, stackTrace) {
      _recordBridgeError('setHideRecentsEnabled', error, stackTrace);
      return const KeepAliveStatus.bridgeError();
    }
  }

  Future<bool> openSettings() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openKeepAliveSettings') ??
          false;
    } catch (error, stackTrace) {
      _recordBridgeError('openKeepAliveSettings', error, stackTrace);
      return false;
    }
  }

  Future<void> syncAuthToken(String? token) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('syncKeepAliveAuthToken', {
        'token': token,
      });
    } catch (error, stackTrace) {
      _recordBridgeError('syncKeepAliveAuthToken', error, stackTrace);
    }
  }

  void _recordBridgeError(
    String operation,
    Object error,
    StackTrace stackTrace,
  ) {
    debugPrint('保活桥接失败（$operation）: $error');
    unawaited(DiagnosticLogService.instance.recordError(
      source: 'Flutter保活桥接',
      type: 'MethodChannel调用失败',
      summary: '保活能力调用失败',
      detail: '$operation\n$error\n$stackTrace',
      eventCode: 'keep_alive_flutter_bridge_failed',
      category: 'platform',
      operation: operation,
    ));
  }
}
