import 'dart:async';

import '../app_platform.dart';
import '../../providers/auth_provider.dart';
import '../../utils/notification_open_target.dart';
import '../../utils/private_message_notification.dart';

typedef PrivateMessageNotificationHandler = Future<bool> Function(
  Map<String, dynamic> message, {
  required bool opened,
  bool showLocalFallback,
});

typedef NotificationOpenHandler = void Function(NotificationOpenTarget target);
typedef PrivateMessageOpenHandler = void Function(PrivateMessageTarget target);

/// 应用通知能力的服务接口。
///
/// 计划阶段 4：业务入口只依赖此中性契约。标准平台实现通过依赖桥接调用
/// JPush / flutter_local_notifications，OHOS 构建则解析为无原生依赖实现。
///
/// 此接口当前为骨架，鸿蒙端通过 [NoopNotificationService] 暴露安全占位；
/// `PlatformCapabilities.supportsJPush` 仍未开通（计划 11.4 编译隔离原则）。
abstract class NotificationService {
  /// 服务绑定的平台。
  AppPlatform get platform;

  /// 当前平台是否已对接且可向用户暴露通知能力。
  /// 未接入前业务页面必须通过此开关决定是否呈现入口。
  bool get isSupported;

  /// 私信本地通知通道是否已初始化。
  bool get isReadyForPrivateMessages;

  /// 注入依赖导航和 Provider 的应用层处理函数。
  void configureHandlers({
    required PrivateMessageNotificationHandler onPrivateMessageNotification,
    required NotificationOpenHandler onNotificationOpenTarget,
    required PrivateMessageOpenHandler onOpenPrivateMessage,
  });

  /// 初始化通知通道与回调。无副作用返回，失败时不应抛出非致命异常。
  Future<void> init();

  /// 请求运行时通知权限。返回是否得到授权；不支持时返回 false。
  Future<bool> requestPermissions();

  /// 初始化标准平台推送并同步当前用户设备标识。
  Future<void> setupPush(AuthProvider authProvider);

  /// 读取原生侧冷启动暂存的私信载荷，读取后由原生侧单次消费。
  Future<String?> getPendingPrivateMessage();

  /// 清除指定会话对应的通知。
  Future<void> clearConversationNotifications(int conversationId);

  /// 当系统推送未展示时，显示私信本地兜底通知。
  Future<void> showLocalPrivateMessage(
    PrivateMessageTarget target,
    Map<String, dynamic> message,
  );

  /// 展示前台/本地通知。`payload` 由具体平台自定义透传。
  Future<void> showLocal({
    required String title,
    required String body,
    String? payload,
  });

  /// 清空所有应用通知（点击消息、未读红点等）。
  Future<void> clearAll();

  /// 反初始化，释放资源。
  Future<void> dispose();
}

/// 无效平台 / 未对接平台的占位实现。
///
/// 所有方法都是 no-op，[isSupported] 严格返回 false。
/// 用于鸿蒙端在 Push/通知能力正式接入前作为安全暴露点
/// （见计划 3.4 未接入能力必须隐藏）。
class NoopNotificationService implements NotificationService {
  const NoopNotificationService({required this.platform});

  @override
  final AppPlatform platform;

  @override
  bool get isSupported => false;

  @override
  bool get isReadyForPrivateMessages => false;

  @override
  void configureHandlers({
    required PrivateMessageNotificationHandler onPrivateMessageNotification,
    required NotificationOpenHandler onNotificationOpenTarget,
    required PrivateMessageOpenHandler onOpenPrivateMessage,
  }) {}

  @override
  Future<void> init() async {}

  @override
  Future<bool> requestPermissions() async => false;

  @override
  Future<void> setupPush(AuthProvider authProvider) async {}

  @override
  Future<String?> getPendingPrivateMessage() async => null;

  @override
  Future<void> clearConversationNotifications(int conversationId) async {}

  @override
  Future<void> showLocalPrivateMessage(
    PrivateMessageTarget target,
    Map<String, dynamic> message,
  ) async {}

  @override
  Future<void> showLocal({
    required String title,
    required String body,
    String? payload,
  }) async {}

  @override
  Future<void> clearAll() async {}

  @override
  Future<void> dispose() async {}
}
