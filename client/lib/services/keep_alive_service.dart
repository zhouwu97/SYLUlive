import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class KeepAliveStatus {
  final bool supported;
  final bool enabled;
  final bool serviceRunning;
  final String manufacturer;
  final int sdkInt;
  final bool isIgnoringBatteryOptimizations;

  const KeepAliveStatus({
    required this.supported,
    required this.enabled,
    required this.serviceRunning,
    required this.manufacturer,
    required this.sdkInt,
    required this.isIgnoringBatteryOptimizations,
  });

  const KeepAliveStatus.unsupported()
      : supported = false,
        enabled = false,
        serviceRunning = false,
        manufacturer = '',
        sdkInt = 0,
        isIgnoringBatteryOptimizations = true;

  factory KeepAliveStatus.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) return const KeepAliveStatus.unsupported();
    return KeepAliveStatus(
      supported: map['supported'] == true,
      enabled: map['enabled'] == true,
      serviceRunning: map['serviceRunning'] == true,
      manufacturer: map['manufacturer']?.toString() ?? '',
      sdkInt: (map['sdkInt'] as num?)?.toInt() ?? 0,
      isIgnoringBatteryOptimizations:
          map['isIgnoringBatteryOptimizations'] != false,
    );
  }
}

class KeepAliveService {
  KeepAliveService._();

  static final KeepAliveService instance = KeepAliveService._();
  static const MethodChannel _channel = MethodChannel('shenliyuan/keep_alive');

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<KeepAliveStatus> status() async {
    if (!_isAndroid) return const KeepAliveStatus.unsupported();
    try {
      final result = await _channel.invokeMapMethod<dynamic, dynamic>(
        'getKeepAliveStatus',
      );
      return KeepAliveStatus.fromMap(result);
    } catch (_) {
      return const KeepAliveStatus.unsupported();
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
    } catch (_) {
      return const KeepAliveStatus.unsupported();
    }
  }

  Future<bool> openSettings() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openKeepAliveSettings') ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> syncAuthToken(String? token) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>(
        'syncKeepAliveAuthToken',
        {'token': token},
      );
    } catch (_) {}
  }
}
