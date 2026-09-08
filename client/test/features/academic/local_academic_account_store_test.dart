import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/academic/data/academic_account_config_client.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/academic/storage/local_academic_account_store.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

const u = AcademicProviderId.syluUndergraduate;
const g = AcademicProviderId.syluGraduate;
AcademicIdentityKey identity(String student,
        {AcademicProviderId provider = u, String user = '1'}) =>
    AcademicIdentityKey(
        appUserId: user, providerId: provider, studentId: student);
Map<String, dynamic> cloud(String student, int revision,
        {String state = 'active', AcademicProviderId provider = u}) =>
    {
      'student_id': student,
      'provider_id': provider.value,
      'revision': revision,
      'state': state
    };

void main() {
  test('本机账号和 Outbox 一次落盘，重启保留本科研究生且 App 账号隔离', () async {
    final prefs = MemoryPreferencesStore();
    final store = LocalAcademicAccountStore('1', prefs);
    await Future.wait([
      store.commitIdentity(identity('same')),
      store.commitIdentity(identity('same', provider: g))
    ]);
    final restarted = LocalAcademicAccountStore('1', prefs);
    expect(restarted.identities.toSet(),
        {identity('same'), identity('same', provider: g)});
    expect(restarted.entry(u)['outbox'], hasLength(1));
    expect(restarted.entry(g)['outbox'], hasLength(1));
    expect(LocalAcademicAccountStore('2', prefs).identities, isEmpty);
    expect(prefs.getString(store.key), isNot(contains('password')));
  });

  test('写入失败不会只留下账号或只留下同步操作', () async {
    final store = LocalAcademicAccountStore('1', _FailingPreferences());
    await expectLater(store.commitIdentity(identity('A')), throwsStateError);
    expect(store.identities, isEmpty);
    expect(store.entry(u)['outbox'], isNull);
  });

  test('离线 A 到 B 的同步响应不能回滚 B，重复恢复不追加同一目标', () async {
    final store = LocalAcademicAccountStore('1', MemoryPreferencesStore());
    await store.commitIdentity(identity('A'));
    final first = (store.entry(u)['outbox'] as List).first;
    await store.commitIdentity(identity('B'));
    await store.commitIdentity(identity('B'));
    expect(store.entry(u)['outbox'], hasLength(2));
    await store.acknowledge(u, first['operation_id'], cloud('A', 1));
    expect(store.identities.single.studentId, 'B');
    expect((store.entry(u)['outbox'] as List).single['base_revision'], 1);
    expect(store.pendingCleanup, [identity('A')]);
  });

  test('删除墓碑跨重启阻止旧 GET 复活，确认删除后也拒绝迟到快照', () async {
    final prefs = MemoryPreferencesStore();
    final store = LocalAcademicAccountStore('1', prefs);
    await store.mergeSnapshot(cloud('A', 1));
    await store.remove(u, fromCloud: true);
    final restarted = LocalAcademicAccountStore('1', prefs);
    await restarted.mergeSnapshot(cloud('A', 1));
    expect(restarted.identities, isEmpty);
    final op = (restarted.entry(u)['outbox'] as List).single;
    await restarted.acknowledge(
        u, op['operation_id'], cloud('', 2, state: 'deleted'));
    await restarted.mergeSnapshot(cloud('A', 1));
    expect(restarted.identities, isEmpty);
    expect(restarted.entry(u)['snapshot']['revision'], 2);
  });

  test('云端变更不改本机学号，显式采用或保留才解决差异', () async {
    final store = LocalAcademicAccountStore('1', MemoryPreferencesStore());
    await store.mergeSnapshot(cloud('A', 1));
    await store.mergeSnapshot(cloud('B', 2));
    expect(store.identities.single.studentId, 'A');
    expect(store.entry(u)['remote_changed'], true);
    await store.keepLocal(u);
    expect((store.entry(u)['outbox'] as List).single['base_revision'], 2);
    await store.adoptCloud(u);
    expect(store.identities.single.studentId, 'B');
    expect(store.entry(u)['outbox'], isEmpty);
  });

  test('旧密码拒绝不能影响新密码代次', () async {
    final store = LocalAcademicAccountStore('1', MemoryPreferencesStore());
    await store.commitIdentity(identity('A'));
    final old = store.epoch(u);
    await store.commitIdentity(identity('A'));
    await store.reject(u, old);
    expect(store.rejected(u), false);
    await store.reject(u, store.epoch(u));
    expect(store.rejected(u), true);
    expect(store.rejected(g), false);
  });

  test('网络重试复用 operationId 与原始 revision，HK 请求不包含秘密', () async {
    final store = LocalAcademicAccountStore('1', MemoryPreferencesStore());
    await store.commitIdentity(identity('A'));
    final requests = <RequestOptions>[];
    var fail = true;
    final dio = Dio();
    addTearDown(dio.close);
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      requests.add(request);
      if (fail) {
        handler.reject(DioException(
            requestOptions: request, type: DioExceptionType.connectionError));
        return;
      }
      handler.resolve(Response(
          requestOptions: request,
          statusCode: 200,
          data: request.method == 'GET'
              ? {
                  'configs': [cloud('A', 1)]
                }
              : {'config': cloud('A', 1)}));
    }));
    final client = AcademicAccountConfigClient(dio);
    await expectLater(
        client.sync(store, () => true), throwsA(isA<DioException>()));
    fail = false;
    await client.sync(store, () => true);
    expect(requests[0].headers['Idempotency-Key'],
        requests[1].headers['Idempotency-Key']);
    expect(requests[0].data, requests[1].data);
    expect(
        requests.every((r) => r.headers['X-Expected-App-User'] == '1'), true);
    expect(requests[0].data, {'student_id': 'A', 'expected_revision': 0});
    expect(store.entry(u)['outbox'], isEmpty);
  });

  test('账号切换后的迟到云端响应不能写入本机快照', () async {
    final store = LocalAcademicAccountStore('1', MemoryPreferencesStore());
    final gate = Completer<void>();
    final started = Completer<void>();
    var current = true;
    final dio = Dio();
    addTearDown(dio.close);
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) async {
      started.complete();
      await gate.future;
      handler.resolve(Response(requestOptions: request, statusCode: 200, data: {
        'configs': [cloud('A', 1)]
      }));
    }));
    final pending = AcademicAccountConfigClient(dio).sync(store, () => current);
    await started.future;
    current = false;
    gate.complete();
    await pending;
    expect(store.identities, isEmpty);
  });

  test('409 保留原操作和本机状态，禁止后台自动刷新版本覆盖另一设备', () async {
    final store = LocalAcademicAccountStore('1', MemoryPreferencesStore());
    await store.commitIdentity(identity('A'));
    final before = (store.entry(u)['outbox'] as List).single;
    final dio = Dio();
    addTearDown(dio.close);
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.method == 'GET') {
        handler
            .resolve(Response(requestOptions: request, statusCode: 200, data: {
          'configs': [cloud('B', 4)]
        }));
        return;
      }
      handler.reject(DioException(
          requestOptions: request,
          type: DioExceptionType.badResponse,
          response: Response(requestOptions: request, statusCode: 409)));
    }));
    await AcademicAccountConfigClient(dio).sync(store, () => true);
    expect(store.entry(u)['conflict'], true);
    expect(store.identities.single.studentId, 'A');
    expect((store.entry(u)['outbox'] as List).single, before);
  });
}

class _FailingPreferences extends MemoryPreferencesStore {
  @override
  Future<bool> setString(String key, String value) async => false;
}
