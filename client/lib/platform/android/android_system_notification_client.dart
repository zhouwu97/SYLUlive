import 'dart:convert';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../contracts/system_notification_client.dart';

class AndroidSystemNotificationClient implements SystemNotificationClient {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  @override
  Future<void> initialize({
    required void Function(Map<String, dynamic> payload) onNotificationTap,
  }) async {
    if (_ready) return;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        _dispatchPayload(response.payload, onNotificationTap);
      },
    );

    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp ?? false) {
      _dispatchPayload(
        launchDetails?.notificationResponse?.payload,
        onNotificationTap,
      );
    }

    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      const channel = AndroidNotificationChannel(
        'private_message_channel',
        '私信通知',
        description: '接收新私信时的横幅和声音提醒',
        importance: Importance.max,
        playSound: true,
        showBadge: true,
        enableVibration: true,
      );
      await androidPlugin.createNotificationChannel(channel);
    }
    _ready = true;
  }

  static void _dispatchPayload(
    String? raw,
    void Function(Map<String, dynamic> payload) onNotificationTap,
  ) {
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        onNotificationTap(
          decoded.map((key, value) => MapEntry(key.toString(), value)),
        );
      }
    } catch (_) {}
  }

  @override
  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
    required Map<String, dynamic> payload,
  }) async {
    if (!_ready) return;

    const androidDetails = AndroidNotificationDetails(
      'private_message_channel',
      '私信通知',
      channelDescription: '接收新私信时的横幅和声音提醒',
      importance: Importance.max,
      priority: Priority.high,
      ticker: '您有一条新私信',
    );
    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      id,
      title,
      body,
      details,
      payload: jsonEncode(payload),
    );
  }

  @override
  Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }
}
