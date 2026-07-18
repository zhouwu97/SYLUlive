import 'dart:async';

import '../app_platform.dart';

/// 深链 / 二维码直达 / 桌面卡片点击进入应用的服务接口。
///
/// 计划 11.2 + 阶段 8：鸿蒙端将基于 `sylulive://competition/<id>`
/// 与 `sylulive://schedule/share/<code>` 协议解析后路由。
/// 当前由 ArkTS `shenliyuan/deeplink` MethodChannel 投递字符串给 Flutter，
/// 阶段 8 Scan Kit 完成后才会真正消费扫码结果。
abstract class DeepLinkService {
  AppPlatform get platform;
  bool get isSupported;

  /// 上层监听此 Stream 获取外部进入的深链原始字符串；
  /// 调用方负责通过 [DeepLinkParser] 校验与预览，禁止直接打开（见计划 13.3 安全要求）。
  Stream<String> get deepLinks;

  /// 上层主动派发一个待处理深链字符串，便于内部跳转重用同一解析管线。
  Future<void> dispatch(String uri);

  /// 清空任何待处理深链（用于退出账号等场景，计划 3.4）。
  Future<void> clearPending();

  Future<void> dispose();
}

class NoopDeepLinkService implements DeepLinkService {
  NoopDeepLinkService({required this.platform});

  @override
  final AppPlatform platform;
  final StreamController<String> _controller =
      StreamController<String>.broadcast();

  @override
  bool get isSupported => false;

  @override
  Stream<String> get deepLinks => _controller.stream;

  @override
  Future<void> dispatch(String uri) async {}

  @override
  Future<void> clearPending() async {}

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}