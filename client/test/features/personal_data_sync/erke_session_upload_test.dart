import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_models.dart';
import 'package:shenliyuan/features/personal_data_sync/erke_snapshot_upload.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/services/account_session_cleanup_coordinator.dart';
import 'package:shenliyuan/services/publish_session_scope.dart';

class _Credentials implements AuthCredentialStore {
  @override
  Future<StoredAuthCredentials> read() async => const StoredAuthCredentials();
  @override
  Future<void> write({required String token, required String userJson}) async {}
  @override
  Future<void> clear() async {}
}

Map<String, dynamic> _user(int id) => {
      'id': id,
      'nickname': '合成用户',
      'created_at': '2026-01-01T00:00:00Z',
      'legal_consents_active': true,
      'legal_consents_required': false,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in [
      'shenliyuan/keep_alive',
      'shenliyuan/grade_reminders',
      'shenliyuan/private_message_notifications',
      'shenliyuan/notification_open'
    ]) {
      messenger.setMockMethodCallHandler(
          MethodChannel(channel), (_) async => null);
    }
  });

  for (final nextUser in [1, 2]) {
    for (final delete in [false, true]) {
      test('请求入队后会话变化拦截二课写入 user=$nextUser delete=$delete', () async {
        final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
        final auth = AuthProvider(dio,
            credentialStore: _Credentials(),
            loadStoredAuth: false,
            sessionCleanupCoordinator: AccountSessionCleanupCoordinator());
        addTearDown(() {
          auth.dispose();
          dio.close();
        });
        await auth.applyAuthPayload('synthetic-A', _user(1));
        final session = PublishSessionScope(
            accountId: 1, accountSessionEpoch: auth.accountSessionEpoch);
        final entered = Completer<void>(), release = Completer<void>();
        var sent = 0;
        // 在真实认证拦截器之前挂起，覆盖“调用方检查后、实际发送前”切号。
        dio.interceptors.insert(0,
            InterceptorsWrapper(onRequest: (request, handler) async {
          entered.complete();
          await release.future;
          handler.next(request);
        }));
        dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
          sent++;
          handler.resolve(Response(
              requestOptions: request,
              statusCode: delete ? 204 : 200,
              data: {}));
        }));
        final uploader = ErkeSnapshotUploadGateway(dio, session: session);
        final result = expectLater(
            delete ? uploader.delete() : uploader.upload(const ErkeSnapshot()),
            throwsA(isA<ErkeSnapshotUploadException>()));
        await entered.future;
        await auth.applyAuthPayload('synthetic-B', _user(nextUser));
        release.complete();
        await result;
        expect(sent, 0);
      });
    }
  }

  test('有效会话正常上传，部分缓存不能上传为完整摘要', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
    final auth = AuthProvider(dio,
        credentialStore: _Credentials(), loadStoredAuth: false);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    await auth.applyAuthPayload('synthetic', _user(1));
    var sent = 0;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      sent++;
      expect(request.extra['expectedAuthUserId'], 1);
      expect(
          request.extra['expectedAuthSessionEpoch'], auth.accountSessionEpoch);
      handler.resolve(
          Response(requestOptions: request, statusCode: 200, data: {}));
    }));
    final uploader = ErkeSnapshotUploadGateway(dio,
        session: PublishSessionScope(
            accountId: 1, accountSessionEpoch: auth.accountSessionEpoch));
    await uploader.upload(const ErkeSnapshot());
    await expectLater(uploader.upload(const ErkeSnapshot(isPartial: true)),
        throwsA(isA<ErkeSnapshotUploadException>()));
    expect(sent, 1);
  });
}
