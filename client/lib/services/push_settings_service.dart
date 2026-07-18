import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/auth_provider.dart';

class RemotePushEnableResult {
  final bool permissionGranted;
  final bool registrationSucceeded;
  final String message;

  const RemotePushEnableResult({
    required this.permissionGranted,
    required this.registrationSucceeded,
    required this.message,
  });
}

typedef RemotePushRegistration = Future<RemotePushEnableResult> Function(
  AuthProvider auth,
);

/// 远程推送主动选择状态。默认关闭，避免旧 Token 被误认为新授权。
class PushSettingsService {
  PushSettingsService._();

  static const enabledKey = 'push_data_processing_enabled';
  static const installationIdKey = 'push_installation_id';
  static const noticeVersion = '2026-07-18-r1';
  static const _aliasChannel = MethodChannel(
    'shenliyuan/private_message_notifications',
  );
  static final FlutterLocalNotificationsPlugin _permissionPlugin =
      FlutterLocalNotificationsPlugin();
  static RemotePushRegistration? _registrationHandler;

  static Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  static Future<bool> isEnabled() async {
    final prefs = await _prefs();
    return prefs.getBool(enabledKey) ?? false;
  }

  static Future<String> installationId() async {
    final prefs = await _prefs();
    final existing = prefs.getString(installationIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final value =
        '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';
    await prefs.setString(installationIdKey, value);
    return value;
  }

  static Future<void> enable() async {
    final prefs = await _prefs();
    await prefs.setBool(enabledKey, true);
  }

  static void configureRemoteRegistration(RemotePushRegistration handler) {
    _registrationHandler = handler;
  }

  /// 用户主动开启远程推送时完成权限申请、设备注册和服务端登记。
  static Future<RemotePushEnableResult> enableAndRegister(
    AuthProvider auth,
  ) async {
    await enable();
    var permissionGranted = false;
    try {
      permissionGranted = await requestSystemNotificationPermission();
    } catch (_) {}

    final handler = _registrationHandler;
    if (handler == null) {
      return RemotePushEnableResult(
        permissionGranted: permissionGranted,
        registrationSucceeded: false,
        message: permissionGranted ? '推送设置已保存，设备注册尚未完成' : '已记录推送选择，但通知权限未允许',
      );
    }
    try {
      final result = await handler(auth);
      if (!permissionGranted && result.registrationSucceeded) {
        return const RemotePushEnableResult(
          permissionGranted: false,
          registrationSucceeded: true,
          message: '已完成设备登记，但系统通知权限未允许',
        );
      }
      return result;
    } catch (_) {
      return RemotePushEnableResult(
        permissionGranted: permissionGranted,
        registrationSucceeded: false,
        message: '推送设置已保存，设备注册失败，请稍后重试',
      );
    }
  }

  /// 仅在用户主动开启远程推送时请求系统权限，冷启动初始化不弹权限框。
  static Future<bool> requestSystemNotificationPermission() async {
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _permissionPlugin.initialize(settings);
    final android = _permissionPlugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      // Android 12 及以下没有运行时通知权限，插件返回 null 代表无需申请。
      return await android.requestNotificationsPermission() ?? true;
    }
    final ios = _permissionPlugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    return await ios?.requestPermissions(
            alert: true, badge: true, sound: true) ??
        true;
  }

  static Future<AuthResult> disable(AuthProvider auth) async {
    final installation = await installationId();
    final result = await auth.updatePushSettings(
      enabled: false,
      installationId: installation,
      registrationId: '',
      noticeVersion: noticeVersion,
    );
    if (!result.success) return result;
    final prefs = await _prefs();
    await prefs.setBool(enabledKey, false);
    try {
      await _aliasChannel.invokeMethod('setPushOptIn', {'enabled': false});
    } catch (_) {
      // 服务端已完成原子关闭；原生链路会在下次启动读取本地状态后停止恢复。
    }
    return result;
  }

  static Future<void> clearLocal() async {
    final prefs = await _prefs();
    await prefs.setBool(enabledKey, false);
    try {
      await _aliasChannel.invokeMethod('setPushOptIn', {'enabled': false});
    } catch (_) {}
  }
}
