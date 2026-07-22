import 'package:flutter/foundation.dart';
import 'package:jpush_flutter/jpush_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../app_platform.dart';
import '../platform_capabilities.dart';

abstract interface class PushClient {
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
  });
  Future<void> clearAlias();
  Future<void> setAlias(String alias);
  Future<void> setTags(List<String> tags);
  Future<bool> requestSystemNotificationPermission();

  factory PushClient.current() {
    if (PlatformCapabilities.current.supportsJPush) {
      return AndroidJPushClient();
    }
    return UnsupportedPushClient();
  }
}

class AndroidJPushClient implements PushClient {
  static final JPush _jpush = JPush();
  static final FlutterLocalNotificationsPlugin _permissionPlugin = FlutterLocalNotificationsPlugin();

  @override
  void setup({
    required String appKey,
    required String channel,
    required bool production,
    required bool debug,
  }) {
    _jpush.setup(
      appKey: appKey,
      channel: channel,
      production: production,
      debug: debug,
    );
    _jpush.applyPushAuthority(
      const NotificationSettingsIOS(sound: true, alert: true, badge: true),
    );
  }

  @override
  Future<String?> getRegistrationId() async {
    try {
      final res = await _jpush.getRegistrationID();
      if (res.isNotEmpty) return res;
    } catch (_) {}
    return null;
  }

  @override
  Future<bool> setPushOptIn(bool enabled) async {
    try {
      if (enabled) {
        await _jpush.resumePush();
      } else {
        await _jpush.stopPush();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void setHandlers({
    Future<dynamic> Function(Map<String, dynamic>)? onReceiveNotification,
    Future<dynamic> Function(Map<String, dynamic>)? onOpenNotification,
    Future<dynamic> Function(Map<String, dynamic>)? onReceiveMessage,
  }) {
    _jpush.addEventHandler(
      onReceiveNotification: onReceiveNotification,
      onOpenNotification: onOpenNotification,
      onReceiveMessage: onReceiveMessage,
    );
  }

  @override
  Future<void> clearAlias() => _jpush.deleteAlias();

  @override
  Future<void> setAlias(String alias) => _jpush.setAlias(alias);

  @override
  Future<void> setTags(List<String> tags) => _jpush.setTags(tags);

  @override
  Future<bool> requestSystemNotificationPermission() async {
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _permissionPlugin.initialize(settings);
    if (!AppPlatforms.current.isAndroid && !AppPlatforms.current.isWeb) {
      final ios = _permissionPlugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      return await ios?.requestPermissions(
              alert: true, badge: true, sound: true) ??
          true;
    }
    final android = _permissionPlugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      return await android.requestNotificationsPermission() ?? true;
    }
    return true;
  }
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
  }) {}

  @override
  Future<void> clearAlias() async {}

  @override
  Future<void> setAlias(String alias) async {}

  @override
  Future<void> setTags(List<String> tags) async {}

  @override
  Future<bool> requestSystemNotificationPermission() async => false;
}
