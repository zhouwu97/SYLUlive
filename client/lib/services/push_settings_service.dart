import 'dart:math';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/auth_provider.dart';

/// 远程推送主动选择状态。默认关闭，避免旧 Token 被误认为新授权。
class PushSettingsService {
  PushSettingsService._();

  static const enabledKey = 'push_data_processing_enabled';
  static const installationIdKey = 'push_installation_id';
  static const noticeVersion = '2026-07-18-r1';
  static const _aliasChannel = MethodChannel(
    'shenliyuan/private_message_notifications',
  );

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
