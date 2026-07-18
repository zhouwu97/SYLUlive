import 'package:jpush_flutter/jpush_flutter.dart';
import 'package:jpush_flutter/jpush_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

typedef PushEventHandler = Future<dynamic> Function(
  Map<String, dynamic> event,
);

typedef LocalNotificationTapHandler = void Function(String payload);

/// 隔离业务层与 JPush 包名，使 OHOS 构建可以替换为无原生依赖实现。
class SylulivePushBridge {
  SylulivePushBridge._() : _pushDelegate = JPush.newJPush();

  final JPushFlutterInterface _pushDelegate;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  static const MethodChannel _privateMessageChannel =
      MethodChannel('shenliyuan/private_message_notifications');

  bool _localNotificationsReady = false;

  bool get localNotificationsReady => _localNotificationsReady;

  static SylulivePushBridge create() => SylulivePushBridge._();

  void setup({
    String appKey = '',
    bool production = false,
    String channel = '',
    bool debug = false,
  }) {
    _pushDelegate.setup(
      appKey: appKey,
      production: production,
      channel: channel,
      debug: debug,
    );
  }

  Future<String> getRegistrationID() => _pushDelegate.getRegistrationID();

  void addEventHandler({
    PushEventHandler? onReceiveNotification,
    PushEventHandler? onOpenNotification,
    PushEventHandler? onNotifyMessageUnShow,
  }) {
    _pushDelegate.addEventHandler(
      onReceiveNotification: onReceiveNotification,
      onOpenNotification: onOpenNotification,
      onNotifyMessageUnShow: onNotifyMessageUnShow,
    );
  }

  Future<void> initializeLocalNotifications({
    required LocalNotificationTapHandler onTap,
  }) async {
    if (_localNotificationsReady) return;

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _localNotifications.initialize(
      settings,
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload != null && payload.isNotEmpty) {
          onTap(payload);
        }
      },
    );

    final android = _localNotifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        'developer-default',
        '系统通知',
        description: '评论、系统通知等',
        importance: Importance.low,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        'private_messages',
        '私信通知',
        description: '收到新私信时悬浮提醒',
        importance: Importance.high,
      ),
    );
    await android?.requestNotificationsPermission();
    _localNotificationsReady = true;
  }

  Future<bool> requestNotificationsPermission() async {
    final android = _localNotifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await android?.requestNotificationsPermission() ?? false;
  }

  Future<void> showLocalNotification({
    required int id,
    required String title,
    required String body,
    required String channelId,
    required String channelName,
    required String channelDescription,
    required bool highPriority,
    String? payload,
  }) async {
    if (!_localNotificationsReady) return;

    await _localNotifications.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: channelDescription,
          importance:
              highPriority ? Importance.high : Importance.defaultImportance,
          priority: highPriority ? Priority.high : Priority.defaultPriority,
        ),
      ),
      payload: payload,
    );
  }

  Future<void> cancelAllLocalNotifications() => _localNotifications.cancelAll();

  Future<void> syncAlias(String userId) => _privateMessageChannel.invokeMethod(
        'syncAlias',
        {'userId': userId},
      );

  Future<void> clearConversationNotifications(int conversationId) =>
      _privateMessageChannel.invokeMethod(
        'clearConversationNotifications',
        {'conversationId': conversationId},
      );

  Future<String?> getPendingPrivateMessage() =>
      _privateMessageChannel.invokeMethod<String>('getPendingPrivateMessage');
}
