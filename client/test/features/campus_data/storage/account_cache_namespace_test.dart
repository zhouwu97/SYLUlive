import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:shenliyuan/features/campus_data/erke/erke_models.dart';
import 'package:shenliyuan/features/campus_data/storage/account_cache_namespace.dart';
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/erke_cache_store.dart';
import 'package:shenliyuan/features/campus_data/storage/physical_cache_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/personal_snapshot_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryPersonalSnapshotSecureStore secureStore;
  late MemoryPersonalSnapshotFileBackend files;
  late IncrementingRandomBytes random;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureStore = MemoryPersonalSnapshotSecureStore();
    files = MemoryPersonalSnapshotFileBackend();
    random = IncrementingRandomBytes();
  });

  AccountScopedSnapshotStore vault(String appUserId) {
    return AesGcmAccountScopedSnapshotStore(
      appUserId: appUserId,
      secureStore: secureStore,
      fileBackend: files,
      randomBytes: random.call,
    );
  }

  test('二课快照按 App 用户和来源账号隔离', () async {
    final owner = ErkeCacheStore(
      appUserId: 'user-a',
      sourceAccountId: 'sid-a',
      snapshotStore: vault('user-a'),
    );
    await owner.saveSnapshot(const ErkeSnapshot(activities: []));

    expect(
      await ErkeCacheStore(
        appUserId: 'user-a',
        sourceAccountId: 'sid-a',
        snapshotStore: vault('user-a'),
      ).loadSnapshot(),
      isNotNull,
    );
    expect(
      await ErkeCacheStore(
        appUserId: 'user-b',
        sourceAccountId: 'sid-a',
        snapshotStore: vault('user-b'),
      ).loadSnapshot(),
      isNull,
    );
    expect(
      await ErkeCacheStore(
        appUserId: 'user-a',
        sourceAccountId: 'sid-b',
        snapshotStore: vault('user-a'),
      ).loadSnapshot(),
      isNull,
    );
  });

  test('阶段 0B 已归属二课明文信封迁入保险箱后删除', () async {
    const appUserId = 'user-a';
    const sourceAccountId = 'sid-a';
    final key = AccountCacheNamespace.erkeSnapshot(appUserId);
    SharedPreferences.setMockInitialValues(<String, Object>{
      key: jsonEncode(<String, dynamic>{
        'app_user_id': AccountCacheNamespace.fingerprint(appUserId),
        'source_account_fingerprint': AccountCacheNamespace.fingerprint(
          sourceAccountId,
        ),
        'schema_version': ErkeCacheStore.schemaVersion,
        'fetched_at': DateTime.utc(2026, 7, 20).toIso8601String(),
        'payload': const ErkeSnapshot(activities: []).toJson(),
      }),
    });
    final store = ErkeCacheStore(
      appUserId: appUserId,
      sourceAccountId: sourceAccountId,
      snapshotStore: vault(appUserId),
    );

    expect(await store.loadSnapshot(), isNotNull);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(key), isFalse);
    expect(files.values, isNotEmpty);
  });

  test('已归属二课明文在密文写入失败时保留供重试', () async {
    const appUserId = 'user-a';
    const sourceAccountId = 'sid-a';
    final key = AccountCacheNamespace.erkeSnapshot(appUserId);
    SharedPreferences.setMockInitialValues(<String, Object>{
      key: jsonEncode(<String, dynamic>{
        'app_user_id': AccountCacheNamespace.fingerprint(appUserId),
        'source_account_fingerprint': AccountCacheNamespace.fingerprint(
          sourceAccountId,
        ),
        'schema_version': ErkeCacheStore.schemaVersion,
        'payload': const ErkeSnapshot(activities: []).toJson(),
      }),
    });
    files.failWrites = true;
    final store = ErkeCacheStore(
      appUserId: appUserId,
      sourceAccountId: sourceAccountId,
      snapshotStore: vault(appUserId),
    );

    expect(await store.loadSnapshot(), isNull);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(key), isTrue);
    expect(await store.needsResync(), isTrue);
  });

  test('无归属旧二课缓存只触发重同步，不自动迁移', () async {
    SharedPreferences.setMockInitialValues({
      'erke_scores_cache': '[{"name":"旧数据"}]',
      'erke_summary_cache': '{}',
      'erke_snapshot': '{}',
    });
    final store = ErkeCacheStore(
      appUserId: 'user-a',
      sourceAccountId: 'sid-a',
      snapshotStore: vault('user-a'),
    );

    expect(await store.loadOrMigrateSnapshot(), isNull);
    expect(await store.needsResync(), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('erke_scores_cache'), isFalse);
  });

  test('体测缓存使用加密账号命名空间并校验来源账号', () async {
    final owner = PhysicalCacheStore(
      appUserId: 'user-a',
      sourceAccountId: 'sid-a',
      snapshotStore: vault('user-a'),
    );
    await owner.writeYear('2026', {'total_score': 90});

    expect(await owner.readYear('2026'), {'total_score': 90});
    expect(
      await PhysicalCacheStore(
        appUserId: 'user-b',
        sourceAccountId: 'sid-a',
        snapshotStore: vault('user-b'),
      ).readYear('2026'),
      isNull,
    );
    expect(
      await PhysicalCacheStore(
        appUserId: 'user-a',
        sourceAccountId: 'sid-b',
        snapshotStore: vault('user-a'),
      ).readYear('2026'),
      isNull,
    );
  });

  test('阶段 0B 已归属体测明文信封迁入保险箱后删除', () async {
    const appUserId = 'user-a';
    const sourceAccountId = 'sid-a';
    const year = '2026';
    final key = AccountCacheNamespace.physicalSnapshot(
      appUserId,
      sourceAccountId,
      year,
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      key: jsonEncode(<String, dynamic>{
        'app_user_id': AccountCacheNamespace.fingerprint(appUserId),
        'source_account_fingerprint': AccountCacheNamespace.fingerprint(
          sourceAccountId,
        ),
        'schema_version': PhysicalCacheStore.schemaVersion,
        'fetched_at': DateTime.utc(2026, 7, 20).toIso8601String(),
        'data': <String, dynamic>{'total_score': 90},
      }),
    });
    final store = PhysicalCacheStore(
      appUserId: appUserId,
      sourceAccountId: sourceAccountId,
      snapshotStore: vault(appUserId),
    );

    expect(await store.readYear(year), {'total_score': 90});

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(key), isFalse);
    expect(files.values, isNotEmpty);
  });

  test('已归属体测明文在密文写入失败时保留供重试', () async {
    const appUserId = 'user-a';
    const sourceAccountId = 'sid-a';
    const year = '2026';
    final key = AccountCacheNamespace.physicalSnapshot(
      appUserId,
      sourceAccountId,
      year,
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      key: jsonEncode(<String, dynamic>{
        'app_user_id': AccountCacheNamespace.fingerprint(appUserId),
        'source_account_fingerprint': AccountCacheNamespace.fingerprint(
          sourceAccountId,
        ),
        'schema_version': PhysicalCacheStore.schemaVersion,
        'data': <String, dynamic>{'total_score': 90},
      }),
    });
    files.failWrites = true;
    final store = PhysicalCacheStore(
      appUserId: appUserId,
      sourceAccountId: sourceAccountId,
      snapshotStore: vault(appUserId),
    );

    expect(await store.readYear(year), isNull);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(key), isTrue);
    expect(await store.needsResync(), isTrue);
  });

  test('体测旧键无法确认归属时被清理并要求重同步', () async {
    SharedPreferences.setMockInitialValues({'gym_cache_sid-a_2026': '{}'});
    final store = PhysicalCacheStore(
      appUserId: 'user-a',
      sourceAccountId: 'sid-a',
      snapshotStore: vault('user-a'),
    );

    await store.discardUnownedLegacy(['2026']);

    expect(await store.needsResync(), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('gym_cache_sid-a_2026'), isFalse);
  });
}
