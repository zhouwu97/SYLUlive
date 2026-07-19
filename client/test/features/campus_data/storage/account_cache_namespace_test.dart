import 'package:flutter_test/flutter_test.dart';

import 'package:shenliyuan/features/campus_data/erke/erke_models.dart';
import 'package:shenliyuan/features/campus_data/storage/account_cache_namespace.dart';
import 'package:shenliyuan/features/campus_data/storage/erke_cache_store.dart';
import 'package:shenliyuan/features/campus_data/storage/physical_cache_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('二课快照按 App 用户和来源账号隔离', () async {
    final owner = ErkeCacheStore(appUserId: 'user-a', sourceAccountId: 'sid-a');
    await owner.saveSnapshot(
      const ErkeSnapshot(activities: []),
    );

    expect(
      await ErkeCacheStore(appUserId: 'user-a', sourceAccountId: 'sid-a')
          .loadSnapshot(),
      isNotNull,
    );
    expect(
      await ErkeCacheStore(appUserId: 'user-b', sourceAccountId: 'sid-a')
          .loadSnapshot(),
      isNull,
    );
    expect(
      await ErkeCacheStore(appUserId: 'user-a', sourceAccountId: 'sid-b')
          .loadSnapshot(),
      isNull,
    );
  });

  test('无归属旧二课缓存只触发重同步，不自动迁移', () async {
    SharedPreferences.setMockInitialValues({
      'erke_scores_cache': '[{"name":"旧数据"}]',
      'erke_summary_cache': '{}',
      'erke_snapshot': '{}',
    });
    final store = ErkeCacheStore(appUserId: 'user-a', sourceAccountId: 'sid-a');

    expect(await store.loadOrMigrateSnapshot(), isNull);
    expect(await store.needsResync(), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('erke_scores_cache'), isFalse);
  });

  test('体测缓存使用三层命名空间并校验信封', () async {
    final owner =
        PhysicalCacheStore(appUserId: 'user-a', sourceAccountId: 'sid-a');
    await owner.writeYear('2026', {'total_score': 90});

    expect(await owner.readYear('2026'), {'total_score': 90});
    expect(
      await PhysicalCacheStore(appUserId: 'user-b', sourceAccountId: 'sid-a')
          .readYear('2026'),
      isNull,
    );
    expect(
      AccountCacheNamespace.physicalSnapshot('user-a', 'sid-a', '2026'),
      contains('/'),
    );
  });

  test('体测旧键无法确认归属时被清理并要求重同步', () async {
    SharedPreferences.setMockInitialValues({'gym_cache_sid-a_2026': '{}'});
    final store =
        PhysicalCacheStore(appUserId: 'user-a', sourceAccountId: 'sid-a');

    await store.discardUnownedLegacy(['2026']);

    expect(await store.needsResync(), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('gym_cache_sid-a_2026'), isFalse);
  });
}
