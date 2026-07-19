import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'account_cache_namespace.dart';

/// 体测缓存仅负责当前 App 用户与当前来源账号的本地命名空间。
class PhysicalCacheStore {
  static const int schemaVersion = 2;
  static const String _legacyPrefix = 'gym_cache_';

  final String appUserId;
  final String sourceAccountId;

  const PhysicalCacheStore({
    required this.appUserId,
    required this.sourceAccountId,
  });

  bool get _hasValidNamespace =>
      appUserId.trim().isNotEmpty && sourceAccountId.trim().isNotEmpty;

  String _key(String year) => AccountCacheNamespace.physicalSnapshot(
        appUserId,
        sourceAccountId,
        year,
      );

  Future<Map<String, dynamic>?> readYear(String year) async {
    if (!_hasValidNamespace) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(year));
    if (raw == null || raw.isEmpty) return null;

    try {
      final envelope = jsonDecode(raw) as Map<String, dynamic>;
      final matchesOwner = envelope['app_user_id'] ==
              AccountCacheNamespace.fingerprint(appUserId) &&
          envelope['source_account_fingerprint'] ==
              AccountCacheNamespace.fingerprint(sourceAccountId) &&
          envelope['schema_version'] == schemaVersion;
      if (!matchesOwner || envelope['data'] is! Map) {
        await prefs.remove(_key(year));
        await _markNeedsResync(prefs);
        return null;
      }
      return Map<String, dynamic>.from(envelope['data'] as Map);
    } catch (_) {
      await prefs.remove(_key(year));
      await _markNeedsResync(prefs);
      return null;
    }
  }

  Future<void> writeYear(String year, Map<String, dynamic> data) async {
    if (!_hasValidNamespace) {
      throw StateError('体测缓存缺少有效的账号命名空间');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(year),
      jsonEncode({
        'app_user_id': AccountCacheNamespace.fingerprint(appUserId),
        'source_account_fingerprint':
            AccountCacheNamespace.fingerprint(sourceAccountId),
        'schema_version': schemaVersion,
        'fetched_at': DateTime.now().toUtc().toIso8601String(),
        'data': data,
      }),
    );
    await prefs.remove(AccountCacheNamespace.physicalNeedsResync(appUserId));
  }

  /// 旧键没有 App 用户归属信息，不能自动迁给当前用户。
  Future<void> discardUnownedLegacy(Iterable<String> years) async {
    if (!_hasValidNamespace) return;
    final prefs = await SharedPreferences.getInstance();
    var discarded = false;
    for (final year in years) {
      discarded =
          await prefs.remove('$_legacyPrefix${sourceAccountId}_$year') ||
              discarded;
    }
    if (discarded) await _markNeedsResync(prefs);
  }

  Future<bool> needsResync() async {
    if (appUserId.trim().isEmpty) return true;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(
          AccountCacheNamespace.physicalNeedsResync(appUserId),
        ) ??
        false;
  }

  Future<void> _markNeedsResync(SharedPreferences prefs) {
    return prefs.setBool(
      AccountCacheNamespace.physicalNeedsResync(appUserId),
      true,
    );
  }
}
