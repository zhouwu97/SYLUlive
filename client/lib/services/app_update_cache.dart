import 'dart:convert';


import '../models/app_update_info.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';


/// 缓存的更新策略与最后一次成功检查时间。
class AppUpdateCacheEntry {
  final AppUpdateInfo info;
  final DateTime checkedAt;

  const AppUpdateCacheEntry({required this.info, required this.checkedAt});
}

/// 更新策略持久化。
///
/// 缓存只用于两个目的：离线时继续拦截已确认的强制更新，以及按服务端建议的
/// 间隔减少前后台重复请求。任何缓存的 none/optional 策略都不能覆盖一次新的
/// required 响应。
class AppUpdateCache {
  static const _entryKey = 'app_update_policy_v1';
  static const _ignoredVersionCodeKey = 'app_update_ignored_version_code_v1';

  Future<AppUpdateCacheEntry?> read() async {
    final prefs = await AppPreferencesStore.getInstance();
    final raw = prefs.getString(_entryKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final checkedAtRaw = decoded['checked_at'];
      if (checkedAtRaw is! String) return null;
      final checkedAt = DateTime.tryParse(checkedAtRaw)?.toUtc();
      final infoRaw = decoded['info'];
      if (checkedAt == null || infoRaw is! Map) return null;
      return AppUpdateCacheEntry(
        info: AppUpdateInfo.fromJson(Map<String, dynamic>.from(infoRaw)),
        checkedAt: checkedAt,
      );
    } catch (_) {
      // 损坏缓存不影响启动；下一次成功检查会自动覆盖。
      return null;
    }
  }

  Future<void> write(AppUpdateInfo info, DateTime checkedAt) async {
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setString(
      _entryKey,
      jsonEncode({
        'checked_at': checkedAt.toUtc().toIso8601String(),
        'info': info.toJson(),
      }),
    );
  }

  Future<bool> isOptionalVersionIgnored(int versionCode) async {
    final prefs = await AppPreferencesStore.getInstance();
    return prefs.getInt(_ignoredVersionCodeKey) == versionCode;
  }

  Future<void> ignoreOptionalVersion(int versionCode) async {
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setInt(_ignoredVersionCodeKey, versionCode);
  }

  Future<void> clearIgnoredVersionWhenChanged(int versionCode) async {
    final prefs = await AppPreferencesStore.getInstance();
    final ignored = prefs.getInt(_ignoredVersionCodeKey);
    if (ignored != null && ignored != versionCode) {
      await prefs.remove(_ignoredVersionCodeKey);
    }
  }
}
