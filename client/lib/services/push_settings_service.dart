import 'dart:math';

import 'package:flutter/services.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

import '../platform/contracts/push_client.dart';
import '../platform/platform_capabilities.dart';
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

class RemotePushSnapshot {
  final bool supported;
  final bool optedIn;
  final bool notificationsEnabled;
  final String? registrationId;
  final String? aliasState;
  final bool privateChannelExists;
  final bool privateChannelBlocked;
  final bool diagnosticsAvailable;
  final String? diagnosticsError;

  const RemotePushSnapshot({
    required this.supported,
    required this.optedIn,
    required this.notificationsEnabled,
    this.registrationId,
    this.aliasState,
    required this.privateChannelExists,
    required this.privateChannelBlocked,
    this.diagnosticsAvailable = true,
    this.diagnosticsError,
  });
}

enum ResolvedPushStatus {
  disabled,
  diagnosticsUnavailable,
  permissionDenied,
  registrationFailed,
  configuring,
  channelUnavailable,
  channelBlocked,
  ready,
}

ResolvedPushStatus resolveRemotePushStatus(RemotePushSnapshot snapshot) {
  if (!snapshot.supported || !snapshot.optedIn) {
    return ResolvedPushStatus.disabled;
  }
  if (!snapshot.diagnosticsAvailable) {
    return ResolvedPushStatus.diagnosticsUnavailable;
  }
  if (!snapshot.notificationsEnabled) {
    return ResolvedPushStatus.permissionDenied;
  }
  if (snapshot.registrationId == null || snapshot.registrationId!.isEmpty) {
    return ResolvedPushStatus.registrationFailed;
  }
  if (snapshot.aliasState == 'pending_bind') {
    return ResolvedPushStatus.configuring;
  }
  if (!snapshot.privateChannelExists) {
    return ResolvedPushStatus.channelUnavailable;
  }
  if (snapshot.privateChannelBlocked) {
    return ResolvedPushStatus.channelBlocked;
  }
  return ResolvedPushStatus.ready;
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
  static final PushClient _pushClient = PushClient.current();
  static RemotePushRegistration? _registrationHandler;
  static Future<RemotePushEnableResult>? _registrationFuture;
  static String? _registrationUserId;

  static Future<AppPreferencesStore> _prefs() =>
      AppPreferencesStore.getInstance();

  static Future<bool> isEnabled() async {
    if (!PlatformCapabilities.current.supportsJPush) return false;
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
    if (!PlatformCapabilities.current.supportsJPush) return;
    final prefs = await _prefs();
    await prefs.setBool(enabledKey, true);
  }

  static void configureRemoteRegistration(RemotePushRegistration handler) {
    _registrationHandler = handler;
    _registrationFuture = null;
    _registrationUserId = null;
  }

  /// 同步原生层的主动选择状态，必须先于 JPush 初始化执行。
  static Future<void> setNativePushOptIn(bool enabled) async {
    if (!PlatformCapabilities.current.supportsJPush) return;
    await _aliasChannel.invokeMethod<void>(
      'setPushOptIn',
      {'enabled': enabled},
    );
  }

  /// 同一账号的注册请求共享 Future，避免设置页和生命周期恢复重复初始化 JPush。
  /// 注册失败时清理 Future，保留后续重试能力。
  static Future<RemotePushEnableResult> registerOnce(AuthProvider auth) {
    final userId = auth.user?.id.toString();
    final existing = _registrationFuture;
    if (existing != null && _registrationUserId == userId) {
      return existing;
    }

    final handler = _registrationHandler;
    if (handler == null) {
      return Future.value(const RemotePushEnableResult(
        permissionGranted: false,
        registrationSucceeded: false,
        message: '推送设置已保存，设备注册尚未完成',
      ));
    }

    final future = Future<RemotePushEnableResult>(() => handler(auth));
    _registrationFuture = future;
    _registrationUserId = userId;
    future.then((result) {
      if (!result.registrationSucceeded &&
          identical(_registrationFuture, future)) {
        _registrationFuture = null;
        _registrationUserId = null;
      }
    }, onError: (_, __) {
      if (identical(_registrationFuture, future)) {
        _registrationFuture = null;
        _registrationUserId = null;
      }
    });
    return future;
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

    try {
      final result = await registerOnce(auth);
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
    if (!PlatformCapabilities.current.supportsJPush) return false;
    return await _pushClient.requestSystemNotificationPermission();
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
    _registrationFuture = null;
    _registrationUserId = null;
    final prefs = await _prefs();
    await prefs.setBool(enabledKey, false);
    try {
      await _aliasChannel.invokeMethod('setPushOptIn', {'enabled': false});
    } catch (_) {
      // 服务端已完成原子关闭；原生链路会在下次启动读取本地状态后停止恢复。
    }
    return result;
  }

  static Future<RemotePushSnapshot> getPushSnapshot() async {
    final supported = PlatformCapabilities.current.supportsJPush;
    if (!supported) {
      return const RemotePushSnapshot(
        supported: false,
        optedIn: false,
        notificationsEnabled: false,
        privateChannelExists: false,
        privateChannelBlocked: false,
        diagnosticsAvailable: true,
      );
    }
    final optedIn = await isEnabled();
    Map<String, dynamic> native = {};
    bool diagnosticsAvailable = true;
    String? diagnosticsError;
    try {
      final result = await _aliasChannel
          .invokeMapMethod<String, dynamic>('getPushDiagnostics');
      native = result ?? {};
    } catch (e) {
      diagnosticsAvailable = false;
      diagnosticsError = e.toString();
    }

    return RemotePushSnapshot(
      supported: true,
      optedIn: optedIn,
      notificationsEnabled: native['notificationsEnabled'] == true,
      registrationId: native['registrationId']?.toString(),
      aliasState: native['storedAliasState']?.toString(),
      privateChannelExists: native['privateMessageChannelExists'] == true,
      privateChannelBlocked: native['privateMessageChannelBlocked'] == true,
      diagnosticsAvailable: diagnosticsAvailable,
      diagnosticsError: diagnosticsError,
    );
  }

  static Future<void> clearLocal() async {
    _registrationFuture = null;
    _registrationUserId = null;
    final prefs = await _prefs();
    await prefs.setBool(enabledKey, false);
    try {
      await _aliasChannel.invokeMethod('setPushOptIn', {'enabled': false});
    } catch (_) {}
  }
}
