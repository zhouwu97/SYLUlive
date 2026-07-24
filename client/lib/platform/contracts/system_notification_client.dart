abstract interface class SystemNotificationClient {
  static SystemNotificationClient? _instance;

  static void register(SystemNotificationClient instance) {
    _instance = instance;
  }

  static SystemNotificationClient current() {
    if (_instance != null) return _instance!;
    _instance = UnsupportedSystemNotificationClient();
    return _instance!;
  }

  Future<void> initialize({
    required void Function(Map<String, dynamic> payload) onNotificationTap,
  });
  
  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
    required Map<String, dynamic> payload,
  });

  Future<void> cancelAll();
}

class UnsupportedSystemNotificationClient implements SystemNotificationClient {
  @override
  Future<void> initialize({
    required void Function(Map<String, dynamic> payload) onNotificationTap,
  }) async {}

  @override
  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
    required Map<String, dynamic> payload,
  }) async {}

  @override
  Future<void> cancelAll() async {}
}
