abstract interface class PushClient {
  static PushClient? _instance;

  static void register(PushClient instance) {
    _instance = instance;
  }

  static PushClient current() {
    if (_instance != null) return _instance!;
    _instance = UnsupportedPushClient();
    return _instance!;
  }

  void setup({
    required String appKey,
    required String channel,
    required bool production,
    required bool debug,
  });
  Future<String?> getRegistrationId();
  Future<bool> setPushOptIn(bool enabled);
  void setHandlers({
    Future<dynamic> Function(Map<String, dynamic>)? onReceiveNotification,
    Future<dynamic> Function(Map<String, dynamic>)? onOpenNotification,
    Future<dynamic> Function(Map<String, dynamic>)? onReceiveMessage,
    Future<dynamic> Function(Map<String, dynamic>)? onNotifyMessageUnShow,
  });
  Future<void> clearAlias();
  Future<void> setTags(List<String> tags);
  Future<bool> requestSystemNotificationPermission();
}

class UnsupportedPushClient implements PushClient {
  @override
  void setup({
    required String appKey,
    required String channel,
    required bool production,
    required bool debug,
  }) {}

  @override
  Future<String?> getRegistrationId() async => null;

  @override
  Future<bool> setPushOptIn(bool enabled) async => false;

  @override
  void setHandlers({
    Future<dynamic> Function(Map<String, dynamic>)? onReceiveNotification,
    Future<dynamic> Function(Map<String, dynamic>)? onOpenNotification,
    Future<dynamic> Function(Map<String, dynamic>)? onReceiveMessage,
    Future<dynamic> Function(Map<String, dynamic>)? onNotifyMessageUnShow,
  }) {}

  @override
  Future<void> clearAlias() async {}

  @override
  Future<void> setTags(List<String> tags) async {}

  @override
  Future<bool> requestSystemNotificationPermission() async => false;
}
