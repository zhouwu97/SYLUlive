import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:jpush_flutter/jpush_flutter.dart';
import 'package:jpush_flutter/jpush_interface.dart';

import '../app_platform.dart';
import '../contracts/push_client.dart';

/// Android 与 iOS 共用的 JPush 适配器。
class JPushClient implements PushClient {
  static final JPushFlutterInterface _jpush = JPush.newJPush();
  static final FlutterLocalNotificationsPlugin _permissionPlugin =
      FlutterLocalNotificationsPlugin();

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
      final registrationId = await _jpush.getRegistrationID();
      if (registrationId.trim().isNotEmpty) {
        return registrationId.trim();
      }
    } catch (_) {
      // 首次启动可能还没有 registration id，由上层生命周期重试。
    }
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
    Future<dynamic> Function(Map<String, dynamic>)? onNotifyMessageUnShow,
  }) {
    _jpush.addEventHandler(
      onReceiveNotification: onReceiveNotification,
      onOpenNotification: onOpenNotification,
      onReceiveMessage: onReceiveMessage,
      onNotifyMessageUnShow: onNotifyMessageUnShow,
    );
  }

  @override
  Future<void> clearAlias() => _jpush.deleteAlias();

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

    if (AppPlatforms.current.isIOS) {
      final ios = _permissionPlugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      return await ios?.requestPermissions(
              alert: true, badge: true, sound: true) ??
          true;
    }
    if (AppPlatforms.current.isAndroid) {
      final android = _permissionPlugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await android?.requestNotificationsPermission() ?? true;
    }
    return false;
  }
}
