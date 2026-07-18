typedef PushEventHandler = Future<dynamic> Function(
  Map<String, dynamic> event,
);

typedef LocalNotificationTapHandler = void Function(String payload);

/// OHOS 首版未开通 JPush，此实现只保持业务层编译契约。
class SylulivePushBridge {
  SylulivePushBridge._();

  static SylulivePushBridge create() => SylulivePushBridge._();

  bool get localNotificationsReady => false;

  void setup({
    String appKey = '',
    bool production = false,
    String channel = '',
    bool debug = false,
  }) {}

  Future<String> getRegistrationID() async => '';

  void addEventHandler({
    PushEventHandler? onReceiveNotification,
    PushEventHandler? onOpenNotification,
    PushEventHandler? onNotifyMessageUnShow,
  }) {}

  Future<void> initializeLocalNotifications({
    required LocalNotificationTapHandler onTap,
  }) async {}

  Future<bool> requestNotificationsPermission() async => false;

  Future<void> showLocalNotification({
    required int id,
    required String title,
    required String body,
    required String channelId,
    required String channelName,
    required String channelDescription,
    required bool highPriority,
    String? payload,
  }) async {}

  Future<void> cancelAllLocalNotifications() async {}

  Future<void> syncAlias(String userId) async {}

  Future<void> clearConversationNotifications(int conversationId) async {}

  Future<String?> getPendingPrivateMessage() async => null;
}
