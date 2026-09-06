import 'package:flutter/services.dart';

import '../models/app_update_info.dart';

/// Android 原生 WorkManager 下载状态。Flutter 仅用于展示和策略判断，不能把它
/// 当作任务的唯一来源，因为 Activity / Flutter engine 可以被系统销毁。
enum AppUpdateDownloadState {
  idle,
  queued,
  downloading,
  paused,
  verifying,
  ready,
  failed,
}

class NativeUpdateDownloadStatus {
  const NativeUpdateDownloadStatus({
    required this.state,
    required this.receivedBytes,
    required this.totalBytes,
    required this.bytesPerSecond,
    this.apkPath,
    this.errorCode,
  });

  final AppUpdateDownloadState state;
  final int receivedBytes;
  final int totalBytes;
  final int bytesPerSecond;
  final String? apkPath;
  final String? errorCode;

  double get progress =>
      totalBytes <= 0 ? 0 : (receivedBytes / totalBytes).clamp(0.0, 1.0);

  bool get isActive =>
      state == AppUpdateDownloadState.queued ||
      state == AppUpdateDownloadState.downloading ||
      state == AppUpdateDownloadState.verifying;

  static const idle = NativeUpdateDownloadStatus(
    state: AppUpdateDownloadState.idle,
    receivedBytes: 0,
    totalBytes: 0,
    bytesPerSecond: 0,
  );

  factory NativeUpdateDownloadStatus.fromMap(Map<Object?, Object?> map) {
    final rawState = map['state'] as String? ?? 'idle';
    final state = AppUpdateDownloadState.values.firstWhere(
      (item) => item.name == rawState,
      orElse: () => AppUpdateDownloadState.idle,
    );
    int intValue(String key) => (map[key] as num?)?.toInt() ?? 0;
    return NativeUpdateDownloadStatus(
      state: state,
      receivedBytes: intValue('receivedBytes'),
      totalBytes: intValue('totalBytes'),
      bytesPerSecond: intValue('bytesPerSecond'),
      apkPath: map['apkPath'] as String?,
      errorCode: map['errorCode'] as String?,
    );
  }
}

class UpdateDownloadBridge {
  static const MethodChannel _channel = MethodChannel('shenliyuan/app_update');

  Future<void> enqueue(
    AppUpdateInfo info, {
    required bool wifiOnly,
    required bool allowBackground,
  }) async {
    await _channel.invokeMethod<void>('enqueueUpdateDownload', {
      ..._releaseArguments(info),
      'wifiOnly': wifiOnly,
      'allowBackground': allowBackground,
    });
  }

  Future<NativeUpdateDownloadStatus> query(AppUpdateInfo info) async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'queryUpdateDownload',
      _releaseArguments(info),
    );
    return result == null
        ? NativeUpdateDownloadStatus.idle
        : NativeUpdateDownloadStatus.fromMap(result);
  }

  Future<void> cancel(AppUpdateInfo info) => _channel.invokeMethod<void>(
        'cancelUpdateDownload',
        _releaseArguments(info),
      );

  Future<void> installPrepared(AppUpdateInfo info) =>
      _channel.invokeMethod<void>(
        'installPreparedUpdate',
        _releaseArguments(info),
      );

  Future<void> clearPrepared(AppUpdateInfo info) => _channel.invokeMethod<void>(
        'clearPreparedUpdate',
        _releaseArguments(info),
      );

  Map<String, Object> _releaseArguments(AppUpdateInfo info) => {
        'versionCode': info.latestVersionCode,
        'versionName': info.latestVersionName,
        'downloadUrl': info.downloadUrl,
        'fileSize': info.fileSize,
        'sha256': info.sha256.toLowerCase(),
      };
}
