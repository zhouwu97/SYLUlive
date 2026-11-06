import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_client.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_models.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_parser.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_repository.dart';
import 'package:shenliyuan/features/campus_data/storage/erke_cache_store.dart';
import 'package:shenliyuan/services/webvpn_service.dart';

class _Vpn extends WebVpnService {
  int logins = 0;
  @override
  Future<bool> login(String username, String password) async {
    logins++;
    return true;
  }
}

class _Cache extends ErkeCacheStore {
  _Cache()
      : super(appUserId: 'fixture-user', sourceAccountId: 'fixture-student');
  ErkeSnapshot? snapshot;
  bool failWrites = false;
  @override
  Future<ErkeSnapshot?> loadOrMigrateSnapshot() async => snapshot;
  @override
  Future<void> saveSnapshot(ErkeSnapshot value) async {
    if (failWrites) throw StateError('fixture storage failure');
    snapshot = value;
  }

  @override
  Future<void> saveFullResult(
          {required ErkeGraduationSummary graduation,
          required ErkeYearlySummary yearly,
          required List<ErkeActivity> activities}) =>
      saveSnapshot(ErkeSnapshot(
          graduation: graduation, yearly: yearly, activities: activities));
}

class _Client extends ErkeClient {
  _Client() : super(dio: Dio());
  Completer<void>? loginGate;
  bool failYear = false;
  bool failActivities = false;
  int logins = 0;
  @override
  Future<void> loginToErke(String username, String password) async {
    logins++;
    await loginGate?.future;
  }

  @override
  Future<ErkeGraduationSummary> getGraduationSummary() async =>
      ErkeParser.parseGraduationSummary(
          File('test/features/campus_data/erke/fixture_graduation.html')
              .readAsStringSync());
  @override
  Future<ErkeYearlySummary> getYearlySummary({String? year}) async {
    if (failYear) throw const ErkePageChangedException('fixture yearly error');
    return ErkeParser.parseYearlySummary(
        File('test/features/campus_data/erke/fixture_yearly.html')
            .readAsStringSync());
  }

  @override
  Future<List<ErkeActivity>> getActivities({String? year}) async {
    if (failActivities) {
      throw const ErkePageChangedException('fixture activities error');
    }
    return const [];
  }
}

void main() {
  late _Vpn vpn;
  late _Cache cache;
  late _Client client;
  late ErkeRepository repo;
  setUp(() {
    vpn = _Vpn();
    cache = _Cache();
    client = _Client();
    repo = ErkeRepository(
        vpnService: vpn, cacheStore: cache, createClient: () => client);
  });
  tearDown(() => vpn.dispose());

  test('部分刷新保留旧时间和完整性标记，重开缓存不会变为新鲜数据', () async {
    final oldTime = DateTime.utc(2026, 1, 1);
    cache.snapshot = ErkeSnapshot(fetchedAt: oldTime);
    client.failYear = true;
    expect(await repo.loginAndFetch('fixture-student', 'cas', 'erke'), isTrue);
    expect(cache.snapshot!.fetchedAt, oldTime);
    expect(cache.snapshot!.toJson()['isPartial'], isTrue);
    repo = ErkeRepository(vpnService: vpn, cacheStore: cache);
    await repo.loadCache();
    expect(repo.lastRefreshPartial, isTrue);
    expect(repo.fetchError, contains('部分'));
  });

  test('活动请求失败时保留磁盘旧活动，不被默认空数组覆盖', () async {
    cache.snapshot = const ErkeSnapshot(activities: [
      ErkeActivity(
          item: 'fixture activity',
          score: '1',
          date: '2026-01-01',
          category: 'A')
    ]);
    client.failActivities = true;
    expect(await repo.loginAndFetch('fixture-student', 'cas', 'erke'), isTrue);
    expect(cache.snapshot!.activities.single.item, 'fixture activity');
    expect(repo.lastRefreshPartial, isTrue);
    expect(repo.credentialsVerified, isTrue);
  });

  test('本地写入失败时保留旧数据，认证成功不被改写为密码错误', () async {
    cache.failWrites = true;
    expect(await repo.loginAndFetch('fixture-student', 'cas', 'erke'), isFalse);
    expect(repo.credentialsVerified, isTrue);
    expect(repo.failureCategory,
        isNot(ErkeFetchFailureCategory.credentialInvalid));
    expect(repo.fetchError, contains('保存失败'));
  });

  test('没有在线会话也能切换已经缓存的学年', () async {
    final yearly = await client.getYearlySummary();
    cache.snapshot = ErkeSnapshot(
        yearlyByYear: {yearly.year: yearly},
        activitiesByYear: {yearly.year: []});
    await repo.fetchYearlySummary(yearly.year);
    expect(repo.yearly?.year, yearly.year);
    expect(repo.yearlyError, isNull);
    expect(vpn.logins, 0);
  });

  test('不同来源账号不能复用当前数据保险箱', () async {
    expect(await repo.loginAndFetch('other-student', 'cas', 'erke'), isFalse);
    expect(vpn.logins, 0);
    expect(cache.snapshot, isNull);
  });

  test('学年失败时仍保存毕业要求和零条活动，不要求重新登录', () async {
    client.failYear = true;
    await repo.loginAndFetch('fixture-student', 'cas', 'erke');
    expect(repo.graduation, isNotNull);
    expect(cache.snapshot?.graduation, isNotNull);
    expect(repo.hasCachedData, isTrue);
    expect(repo.hasLiveSession, isTrue);
  });

  test('重复刷新只登录一次', () async {
    client.loginGate = Completer<void>();
    final first = repo.loginAndFetch('fixture-student', 'cas', 'erke');
    final second = repo.loginAndFetch('fixture-student', 'cas', 'erke');
    await Future<void>.delayed(Duration.zero);
    client.loginGate!.complete();
    await Future.wait([first, second]);
    expect(vpn.logins, 1);
  });

  test('重置会话后旧登录请求不能恢复会话或写缓存', () async {
    client.loginGate = Completer<void>();
    final pending = repo.loginAndFetch('fixture-student', 'cas', 'erke');
    await Future<void>.delayed(Duration.zero);
    repo.resetLiveSession();
    client.loginGate!.complete();
    await pending;
    expect(repo.hasLiveSession, isFalse);
    expect(cache.snapshot, isNull);
  });

  test('外部账号代次在认证途中失效后不再抓取或写入', () async {
    var current = true;
    repo = ErkeRepository(
        vpnService: vpn,
        cacheStore: cache,
        createClient: () => client,
        isCurrent: () => current);
    client.loginGate = Completer<void>();
    final pending = repo.loginAndFetch('fixture-student', 'cas', 'erke');
    await Future<void>.delayed(Duration.zero);
    current = false;
    client.loginGate!.complete();
    expect(await pending, isFalse);
    expect(cache.snapshot, isNull);
    expect(repo.hasLiveSession, isFalse);
  });
}
