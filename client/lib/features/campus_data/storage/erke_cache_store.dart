import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../erke/erke_models.dart';
import 'account_cache_namespace.dart';
import 'account_scoped_snapshot_store.dart';
import 'personal_snapshot_models.dart';

/// 二课数据缓存，仅允许访问当前 App 用户与来源账号的命名空间。
///
/// 新写入只进入 AES-GCM 文件保险箱。阶段 0B 的已归属明文信封会在首次
/// 读取时执行“写入密文 -> 回读校验 -> 删除旧值”；无法确认归属的更早旧键
/// 仍然只清理并要求用户重新同步。
class ErkeCacheStore {
  static const int schemaVersion = 2;
  static const _legacyKeys = <String>[
    'erke_scores_cache',
    'erke_summary_cache',
    'erke_snapshot',
  ];

  ErkeCacheStore({
    required this.appUserId,
    required this.sourceAccountId,
    AccountScopedSnapshotStore? snapshotStore,
  }) : _snapshotStore = snapshotStore ??
            AesGcmAccountScopedSnapshotStore(appUserId: appUserId);

  final String appUserId;
  final String sourceAccountId;
  final AccountScopedSnapshotStore _snapshotStore;

  bool get _hasValidNamespace =>
      appUserId.trim().isNotEmpty && sourceAccountId.trim().isNotEmpty;

  String get _legacyOwnedSnapshotKey =>
      AccountCacheNamespace.erkeSnapshot(appUserId);

  String get _needsResyncKey =>
      AccountCacheNamespace.erkeNeedsResync(appUserId);

  Future<ErkeSnapshot?> loadOrMigrateSnapshot() async {
    final existing = await loadSnapshot();
    if (existing != null) return existing;

    // 更早的全局旧格式没有可靠的 App 用户和来源学号元数据，禁止猜测归属。
    await _discardUnownedLegacyCache();
    return null;
  }

  Future<ErkeSnapshot?> loadSnapshot() async {
    if (!_hasValidNamespace) return null;

    try {
      final encrypted = await _snapshotStore.read(
        type: PersonalDataType.erke,
        sourceSystem: 'erke',
        sourceAccountId: sourceAccountId,
      );
      if (encrypted != null) {
        return ErkeSnapshot.fromJson(encrypted.payload);
      }
      return _migrateOwnedPlaintextSnapshot();
    } on PersonalSnapshotStoreException {
      await _markNeedsResync();
      return null;
    } catch (_) {
      await _markNeedsResync();
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
    return await loadSnapshot() != null;
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
    await _snapshotStore.write(
      type: PersonalDataType.erke,
      schemaVersion: schemaVersion,
      sourceSystem: 'erke',
      sourceAccountId: sourceAccountId,
      fetchedAt: snapshot.fetchedAt ?? DateTime.now(),
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 7)),
      payload: snapshot.toJson(),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_needsResyncKey);
    // 新写入成功后清理阶段 0B 明文信封。
    await prefs.remove(_legacyOwnedSnapshotKey);
  }

  Future<void> saveYearlySummary(
    ErkeYearlySummary yearly,
    List<ErkeActivity> yearActivities,
  ) async {
    final snapshot = await loadSnapshot();
    await saveSnapshot(
      ErkeSnapshot(
        graduation: snapshot?.graduation,
        yearly: yearly,
        yearlyByYear: {...?snapshot?.yearlyByYear, yearly.year: yearly},
        activities: snapshot?.activities ?? const [],
        activitiesByYear: {
          ...?snapshot?.activitiesByYear,
          yearly.year: yearActivities,
        },
        fetchedAt: DateTime.now(),
      ),
    );
  }

  Future<void> saveActivities(List<ErkeActivity> activities) async {
    final snapshot = await loadSnapshot();
    await saveSnapshot(
      ErkeSnapshot(
        graduation: snapshot?.graduation,
        yearly: snapshot?.yearly,
        yearlyByYear: snapshot?.yearlyByYear ?? const {},
        activities: activities,
        activitiesByYear: snapshot?.activitiesByYear ?? const {},
        fetchedAt: DateTime.now(),
      ),
    );
  }

  Future<void> saveFullResult({
    required ErkeGraduationSummary graduation,
    required ErkeYearlySummary yearly,
    required List<ErkeActivity> activities,
  }) async {
    await saveSnapshot(
      ErkeSnapshot(
        graduation: graduation,
        yearly: yearly,
        yearlyByYear: {yearly.year: yearly},
        activities: activities,
        activitiesByYear: {yearly.year: activities},
        fetchedAt: DateTime.now(),
      ),
    );
  }

  Future<void> clearAll() async {
    await _snapshotStore.deleteType(PersonalDataType.erke);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_legacyOwnedSnapshotKey);
    await prefs.remove(_needsResyncKey);
    for (final key in _legacyKeys) {
      await prefs.remove(key);
    }
  }

  Future<void> close() => _snapshotStore.close();

  Future<ErkeSnapshot?> _migrateOwnedPlaintextSnapshot() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_legacyOwnedSnapshotKey);
    if (raw == null || raw.isEmpty) return null;

    ErkeSnapshot migrated;
    try {
      final envelope = jsonDecode(raw) as Map<String, dynamic>;
      final matchesOwner = envelope['app_user_id'] ==
              AccountCacheNamespace.fingerprint(appUserId) &&
          envelope['source_account_fingerprint'] ==
              AccountCacheNamespace.fingerprint(sourceAccountId) &&
          envelope['schema_version'] == schemaVersion &&
          envelope['payload'] is Map;
      if (!matchesOwner) {
        await prefs.remove(_legacyOwnedSnapshotKey);
        await _markNeedsResync(prefs);
        return null;
      }
      migrated = ErkeSnapshot.fromJson(
        Map<String, dynamic>.from(envelope['payload'] as Map),
      );
    } catch (_) {
      // 无法解析或证明归属的明文不能迁给当前用户。
      await prefs.remove(_legacyOwnedSnapshotKey);
      await _markNeedsResync(prefs);
      return null;
    }

    try {
      await _snapshotStore.write(
        type: PersonalDataType.erke,
        schemaVersion: schemaVersion,
        sourceSystem: 'erke',
        sourceAccountId: sourceAccountId,
        fetchedAt: migrated.fetchedAt ?? DateTime.now(),
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 7)),
        payload: migrated.toJson(),
      );
      final verified = await _snapshotStore.read(
        type: PersonalDataType.erke,
        sourceSystem: 'erke',
        sourceAccountId: sourceAccountId,
      );
      if (verified == null) {
        throw const PersonalSnapshotStoreException('二课密文迁移校验失败');
      }
      await prefs.remove(_legacyOwnedSnapshotKey);
      await prefs.remove(_needsResyncKey);
      return ErkeSnapshot.fromJson(verified.payload);
    } catch (_) {
      // 已确认归属的数据在密文写入或回读失败时必须保留，供下次重试。
      await _markNeedsResync(prefs);
      return null;
    }
  }

  Future<void> _discardUnownedLegacyCache() async {
    if (!_hasValidNamespace) return;
    final prefs = await SharedPreferences.getInstance();
    var discarded = false;
    for (final key in _legacyKeys) {
      discarded = await prefs.remove(key) || discarded;
    }
    if (discarded) await _markNeedsResync(prefs);
  }

  Future<void> _markNeedsResync([SharedPreferences? preferences]) async {
    if (!_hasValidNamespace) return;
    final prefs = preferences ?? await SharedPreferences.getInstance();
    await prefs.setBool(_needsResyncKey, true);
  }
}
