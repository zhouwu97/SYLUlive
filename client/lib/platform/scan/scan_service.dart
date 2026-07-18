import 'dart:async';

import 'package:flutter/services.dart';

import '../app_platform.dart';

/// 鸿蒙 Scan Kit 扫码能力的服务接口（计划阶段 8）。
///
/// 支持的扫码场景（计划 13.1）：
///   竞赛详情二维码 `sylulive://competition/<id>`
///   课表分享码 `sylulive://schedule/share/<code>`
///
/// 安全约束（计划 13.3）：
///   1. 上层必须校验 URI 协议与 ID/分享码格式；
///   2. 任何导入/打开操作前必须预览；
///   3. 不允许扫描结果直接覆盖用户数据。
abstract class ScanService {
  AppPlatform get platform;
  bool get isSupported;

  /// 拉起 Scan Kit 扫码界面。返回扫码结果原始字符串；用户取消或无摄像头时返回 null。
  /// `kind` 用于鸿蒙端选择不同的 Scan Kit 模板（二维码 / 多码等）。
  Future<String?> scan({ScanKind kind = ScanKind.qrcode});

  Future<void> dispose();
}

/// 鸿蒙 Scan Kit 扫码类型。后续阶段可按官方能力扩展。
enum ScanKind { qrcode, multicode }

/// 未对接平台的占位实现。直接返回 null，等同用户取消。
/// 鸿蒙 ArkTS 桥接验收通过后切换真实实现（计划 13.4 末段）。
class NoopScanService implements ScanService {
  const NoopScanService({required this.platform});

  @override
  final AppPlatform platform;

  @override
  bool get isSupported => false;

  @override
  Future<String?> scan({ScanKind kind = ScanKind.qrcode}) async => null;

  @override
  Future<void> dispose() async {}
}

/// HarmonyOS Scan Kit 的 Flutter 通道实现。
///
/// 原生端只负责拉起系统扫码界面并返回原始字符串，业务协议解析和确认流程
/// 保留在 Dart 层，避免原生插件承担业务路由责任。
class OhosScanService implements ScanService {
  OhosScanService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'com.sylulive.harmony/scan';
  final MethodChannel _channel;

  @override
  AppPlatform get platform => AppPlatform.ohos;

  @override
  bool get isSupported => true;

  @override
  Future<String?> scan({ScanKind kind = ScanKind.qrcode}) async {
    try {
      return await _channel.invokeMethod<String>('scan', <String, Object?>{
        'kind': kind.name,
      });
    } on PlatformException catch (error) {
      if (error.code == 'scan_cancelled') return null;
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {}
}
