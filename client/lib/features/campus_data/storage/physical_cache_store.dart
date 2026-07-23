import 'dart:convert';


import 'account_cache_namespace.dart';
import 'account_scoped_snapshot_store.dart';
import 'personal_snapshot_models.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';


/// 体测缓存仅负责当前 App 用户与当前来源账号的本地命名空间。
///
/// 所有年份聚合在同一份 AES-GCM 快照中。阶段 0B 的逐年明文信封会在
/// 首次读取对应年份时复制、回读校验并删除。
class PhysicalCacheStore {
  static const int schemaVersion = 2;
  static const String _legacyPrefix = 'gym_cache_';

  // 同一账号的 physical.bin 只能串行执行读改写，避免不同年份互相覆盖。
  static final Map<String, Future<void>> _physicalMutationTails =
      <String, Future<void>>{};

  PhysicalCacheStore({
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

  String _legacyOwnedKey(String year) =>
      AccountCacheNamespace.physicalSnapshot(appUserId, sourceAccountId, year);

  Future<Map<String, dynamic>?> readYear(String year) async {
    if (!_hasValidNamespace || year.trim().isEmpty) return null;
    try {
      final years = await _readEncryptedYears();
      final value = years[year];
      if (value is Map) return Map<String, dynamic>.from(value);
      return _migrateOwnedPlaintextYear(year);
    } on PersonalSnapshotStoreException {
      await _markNeedsResync();
      return null;
    } catch (_) {
      await _markNeedsResync();
      return null;
    }
  }

  Future<void> writeYear(String year, Map<String, dynamic> data) async {
    if (!_hasValidNamespace) {
      throw StateError('体测缓存缺少有效的账号命名空间');
    }
    if (year.trim().isEmpty) {
      throw ArgumentError.value(year, 'year');
    }

    await _serializePhysicalMutation(() async {
      final years = await _readEncryptedYears();
      years[year] = Map<String, dynamic>.from(data);
      await _writeEncryptedYears(years);
    });

    final prefs = await AppPreferencesStore.getInstance();
    await prefs.remove(_legacyOwnedKey(year));
    await prefs.remove(AccountCacheNamespace.physicalNeedsResync(appUserId));
  }

  /// 更早旧键没有 App 用户归属信息，不能自动迁给当前用户。
  Future<void> discardUnownedLegacy(Iterable<String> years) async {
    if (!_hasValidNamespace) return;
    final prefs = await AppPreferencesStore.getInstance();
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
    final prefs = await AppPreferencesStore.getInstance();
    return prefs.getBool(
          AccountCacheNamespace.physicalNeedsResync(appUserId),
        ) ??
        false;
  }

  Future<void> clearAll() async {
    await _serializePhysicalMutation(() async {
      await _snapshotStore.deleteType(PersonalDataType.physical);
      final prefs = await AppPreferencesStore.getInstance();
      final ownedPrefix =
          'physical/${AccountCacheNamespace.fingerprint(appUserId)}/';
      final keys =
          prefs.getKeys().where((key) => key.startsWith(ownedPrefix)).toList();
      for (final key in keys) {
        await prefs.remove(key);
      }
      await prefs.remove(AccountCacheNamespace.physicalNeedsResync(appUserId));
    });
  }

  Future<void> close() => _snapshotStore.close();

  Future<Map<String, dynamic>> _readEncryptedYears() async {
    final snapshot = await _snapshotStore.read(
      type: PersonalDataType.physical,
      sourceSystem: 'physical',
      sourceAccountId: sourceAccountId,
    );
    if (snapshot == null) return <String, dynamic>{};
    final years = snapshot.payload['years'];
    if (years is! Map) {
      throw const PersonalSnapshotStoreException('体测密文快照格式错误');
    }
    return Map<String, dynamic>.from(years);
  }

  Future<void> _writeEncryptedYears(Map<String, dynamic> years) {
    return _snapshotStore.write(
      type: PersonalDataType.physical,
      schemaVersion: schemaVersion,
      sourceSystem: 'physical',
      sourceAccountId: sourceAccountId,
      fetchedAt: DateTime.now(),
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
      payload: <String, dynamic>{'years': years},
    );
  }

  Future<Map<String, dynamic>?> _migrateOwnedPlaintextYear(String year) async {
    try {
      return await _serializePhysicalMutation(() async {
        // 入队后重新读取密文，避免旧明文迁移覆盖刚完成的同步结果。
        final years = await _readEncryptedYears();
        final existing = years[year];
        if (existing is Map) return Map<String, dynamic>.from(existing);

        final prefs = await AppPreferencesStore.getInstance();
        final key = _legacyOwnedKey(year);
        final raw = prefs.getString(key);
        if (raw == null || raw.isEmpty) return null;

        late Map<String, dynamic> data;
        try {
          final envelope = jsonDecode(raw) as Map<String, dynamic>;
          final matchesOwner = envelope['app_user_id'] ==
                  AccountCacheNamespace.fingerprint(appUserId) &&
              envelope['source_account_fingerprint'] ==
                  AccountCacheNamespace.fingerprint(sourceAccountId) &&
              envelope['schema_version'] == schemaVersion &&
              envelope['data'] is Map;
          if (!matchesOwner) {
            await prefs.remove(key);
            await _markNeedsResync(prefs);
            return null;
          }
          data = Map<String, dynamic>.from(envelope['data'] as Map);
        } catch (_) {
          // 无法解析或证明归属的明文不能迁给当前用户。
          await prefs.remove(key);
          await _markNeedsResync(prefs);
          return null;
        }

        years[year] = data;
        await _writeEncryptedYears(years);
        final verified = await _readEncryptedYears();
        if (verified[year] is! Map) {
          throw const PersonalSnapshotStoreException('体测密文迁移校验失败');
        }

        await prefs.remove(key);
        await prefs
            .remove(AccountCacheNamespace.physicalNeedsResync(appUserId));
        return Map<String, dynamic>.from(verified[year] as Map);
      });
    } catch (_) {
      // 已确认归属的数据在密文写入或回读失败时必须保留，供下次重试。
      await _markNeedsResync();
      return null;
    }
  }

  Future<T> _serializePhysicalMutation<T>(
    Future<T> Function() operation,
  ) {
    final queueKey =
        '${_snapshotStore.accountFingerprint}/${PersonalDataType.physical.storageValue}';
    final previous = _physicalMutationTails[queueKey] ?? Future<void>.value();
    final guarded = previous.then<T>((_) => operation());
    final tail = guarded.then<void>(
      (_) {},
      onError: (error, stackTrace) {},
    );
    _physicalMutationTails[queueKey] = tail;

    return guarded.whenComplete(() {
      if (identical(_physicalMutationTails[queueKey], tail)) {
        _physicalMutationTails.remove(queueKey);
      }
    });
  }

  Future<void> _markNeedsResync([AppPreferencesStore? preferences]) async {
    if (appUserId.trim().isEmpty) return;
    final prefs = preferences ?? await AppPreferencesStore.getInstance();
    await prefs.setBool(
      AccountCacheNamespace.physicalNeedsResync(appUserId),
      true,
    );
  }
}
