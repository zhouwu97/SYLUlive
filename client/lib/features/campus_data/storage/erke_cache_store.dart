import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../erke/erke_models.dart';
import 'account_cache_namespace.dart';

/// 二课数据缓存，仅允许访问当前 App 用户与来源账号的命名空间。
class ErkeCacheStore {
  static const int schemaVersion = 2;
  static const _legacyKeys = <String>[
    'erke_scores_cache',
    'erke_summary_cache',
    'erke_snapshot',
  ];

  final String appUserId;
  final String sourceAccountId;

  const ErkeCacheStore({
    required this.appUserId,
    required this.sourceAccountId,
  });

  bool get _hasValidNamespace =>
      appUserId.trim().isNotEmpty && sourceAccountId.trim().isNotEmpty;

  String get _snapshotKey => AccountCacheNamespace.erkeSnapshot(appUserId);

  String get _needsResyncKey =>
      AccountCacheNamespace.erkeNeedsResync(appUserId);

  Future<ErkeSnapshot?> loadOrMigrateSnapshot() async {
    final existing = await loadSnapshot();
    if (existing != null) return existing;

    // 旧格式没有可靠的 App 用户和来源学号元数据，禁止猜测归属。
    await _discardUnownedLegacyCache();
    return null;
  }

  Future<ErkeSnapshot?> loadSnapshot() async {
    if (!_hasValidNamespace) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_snapshotKey);
    if (raw == null || raw.isEmpty) return null;

    try {
      final envelope = jsonDecode(raw) as Map<String, dynamic>;
      final matchesOwner = envelope['app_user_id'] ==
              AccountCacheNamespace.fingerprint(appUserId) &&
          envelope['source_account_fingerprint'] ==
              AccountCacheNamespace.fingerprint(sourceAccountId) &&
          envelope['schema_version'] == schemaVersion;
      if (!matchesOwner || envelope['payload'] is! Map) {
        await prefs.remove(_snapshotKey);
        await prefs.setBool(_needsResyncKey, true);
        return null;
      }
      return ErkeSnapshot.fromJson(
        Map<String, dynamic>.from(envelope['payload'] as Map),
      );
    } catch (_) {
      await prefs.remove(_snapshotKey);
      await prefs.setBool(_needsResyncKey, true);
      return null;
    }
  }

  Future<List<ErkeActivity>> loadActivities() async {
    final snapshot = await loadSnapshot();
    return snapshot?.activities ?? const [];
  }

  Future<ErkeGraduationSummary?> loadGraduation() async {
    return (await loadSnapshot())?.graduation;
  }

  Future<ErkeYearlySummary?> loadYearly() async {
    return (await loadSnapshot())?.yearly;
  }

  Future<ErkeYearlySummary?> loadYearlyForYear(String year) async {
    return (await loadSnapshot())?.yearlyByYear[year];
  }

  Future<bool> hasCache() async {
    if (!_hasValidNamespace) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_snapshotKey);
  }

  Future<bool> needsResync() async {
    if (!_hasValidNamespace) return true;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_needsResyncKey) ?? false;
  }

  Future<void> saveSnapshot(ErkeSnapshot snapshot) async {
    if (!_hasValidNamespace) {
      throw StateError('二课缓存缺少有效的账号命名空间');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _snapshotKey,
      jsonEncode({
        'app_user_id': AccountCacheNamespace.fingerprint(appUserId),
        'source_account_fingerprint':
            AccountCacheNamespace.fingerprint(sourceAccountId),
        'schema_version': schemaVersion,
        'fetched_at':
            (snapshot.fetchedAt ?? DateTime.now()).toUtc().toIso8601String(),
        'payload': snapshot.toJson(),
      }),
    );
    await prefs.remove(_needsResyncKey);
  }

  Future<void> saveYearlySummary(
    ErkeYearlySummary yearly,
    List<ErkeActivity> yearActivities,
  ) async {
    final snapshot = await loadSnapshot();
    await saveSnapshot(ErkeSnapshot(
      graduation: snapshot?.graduation,
      yearly: yearly,
      yearlyByYear: {...?snapshot?.yearlyByYear, yearly.year: yearly},
      activities: snapshot?.activities ?? const [],
      activitiesByYear: {
        ...?snapshot?.activitiesByYear,
        yearly.year: yearActivities,
      },
      fetchedAt: DateTime.now(),
    ));
  }

  Future<void> saveActivities(List<ErkeActivity> activities) async {
    final snapshot = await loadSnapshot();
    await saveSnapshot(ErkeSnapshot(
      graduation: snapshot?.graduation,
      yearly: snapshot?.yearly,
      yearlyByYear: snapshot?.yearlyByYear ?? const {},
      activities: activities,
      activitiesByYear: snapshot?.activitiesByYear ?? const {},
      fetchedAt: DateTime.now(),
    ));
  }

  Future<void> saveFullResult({
    required ErkeGraduationSummary graduation,
    required ErkeYearlySummary yearly,
    required List<ErkeActivity> activities,
  }) async {
    await saveSnapshot(ErkeSnapshot(
      graduation: graduation,
      yearly: yearly,
      yearlyByYear: {yearly.year: yearly},
      activities: activities,
      activitiesByYear: {yearly.year: activities},
      fetchedAt: DateTime.now(),
    ));
  }

  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    if (_hasValidNamespace) {
      await prefs.remove(_snapshotKey);
      await prefs.remove(_needsResyncKey);
    }
    for (final key in _legacyKeys) {
      await prefs.remove(key);
    }
  }

  Future<void> _discardUnownedLegacyCache() async {
    if (!_hasValidNamespace) return;
    final prefs = await SharedPreferences.getInstance();
    var discarded = false;
    for (final key in _legacyKeys) {
      discarded = await prefs.remove(key) || discarded;
    }
    if (discarded) await prefs.setBool(_needsResyncKey, true);
  }
}
