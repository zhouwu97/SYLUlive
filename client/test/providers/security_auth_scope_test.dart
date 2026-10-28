import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/services/account_session_cleanup_coordinator.dart';
import 'package:shenliyuan/services/admin_security_service.dart';
import 'package:shenliyuan/services/publish_session_scope.dart';

class _Credentials implements AuthCredentialStore {
  StoredAuthCredentials stored = const StoredAuthCredentials();
  bool failWrite = false;
  Completer<void>? writeStarted;
  Completer<void>? releaseWrite;
  @override
  Future<StoredAuthCredentials> read() async => stored;
  @override
  Future<void> clear() async => stored = const StoredAuthCredentials();
  @override
  Future<void> write({required String token, required String userJson}) async {
    if (failWrite) throw StateError('synthetic storage failure');
    if (token == 'updated-a' && writeStarted != null) {
      writeStarted!.complete();
      await releaseWrite!.future;
    }
    stored = StoredAuthCredentials(token: token, userJson: userJson);
  }
}

Map<String, dynamic> _user(int id) => {
      'id': id,
      'student_id': '',
      'nickname': '验收用户$id',
      'role': 'super_admin',
      'created_at': '2026-01-01T00:00:00Z',
      'legal_consents_active': true,
      'legal_consents_required': false
    };
Map<String, dynamic> _session(String token, int id,
        {int expiresMinutes = 60}) =>
    {
      'token': token,
      'refresh_token': 'refresh-$token',
      'expires_at': DateTime.now()
          .add(Duration(minutes: expiresMinutes))
          .toUtc()
          .toIso8601String(),
      'user': _user(id),
    };

class _Adapter implements HttpClientAdapter {
  final refreshStarted = Completer<void>();
  final releaseRefresh = Completer<void>();
  final operationStarted = Completer<void>();
  final releaseOperation = Completer<void>();
  final requests = <RequestOptions>[];
  bool holdOperation = false;
  int responseUser = 1;
  int loginMinutes = 1;
  bool holdProfile = false;
  bool updatedEmailBound = false;
  final profileStarted = Completer<void>();
  final releaseProfile = Completer<void>();
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    await requestStream?.drain<void>();
    Object body;
    if (options.path == '/login') {
      body = _session('token-a', 1, expiresMinutes: loginMinutes);
    } else if (options.path == '/refresh') {
      refreshStarted.complete();
      await releaseRefresh.future;
      body = _session('refreshed-a', 1);
    } else {
      requests.add(options);
      if (options.path == '/user/profile' && holdProfile) {
        profileStarted.complete();
        await releaseProfile.future;
        return ResponseBody.fromString(jsonEncode(_user(1)), 200, headers: {
          Headers.contentTypeHeader: ['application/json']
        });
      }
      if (holdOperation && options.path != '/logout') {
        operationStarted.complete();
        await releaseOperation.future;
      }
      body = switch (options.path) {
        '/super/security/blocks' when options.method == 'GET' => [],
        '/admin/security/events' => {'items': [], 'total': 0},
        '/admin/security/overview' => {'range': '24h'},
        '/user/account-security' => {'email': 'synthetic-a@example.test'},
        '/change_password' || '/user/email' => {
            ..._session('updated-a', responseUser),
            'user': {..._user(responseUser), 'email_bound': updatedEmailBound}
          },
        _ => {'message': '成功'},
      };
    }
    return ResponseBody.fromString(jsonEncode(body), 200, headers: {
      Headers.contentTypeHeader: ['application/json']
    });
  }
}

typedef _Invoke = Future<Object?> Function(
    AuthProvider, AdminSecurityService, PublishSessionScope);
final _operations = <({String name, bool admin, _Invoke invoke})>[
  (
    name: '读取私有资料',
    admin: false,
    invoke: (a, service, scope) => a.getAccountSecurity()
  ),
  (
    name: '发送验证码',
    admin: false,
    invoke: (a, service, scope) =>
        a.requestUserEmailCode('synthetic@example.test')
  ),
  (
    name: '换绑邮箱',
    admin: false,
    invoke: (a, service, scope) => a.updateUserEmail(
        email: 'synthetic@example.test',
        code: '123456',
        password: 'synthetic-password')
  ),
  (
    name: '解除邮箱',
    admin: false,
    invoke: (a, service, scope) => a.removeUserEmail('synthetic-password')
  ),
  (
    name: '修改密码',
    admin: false,
    invoke: (a, service, scope) =>
        a.changePassword('synthetic-old', 'synthetic-new')
  ),
  (name: '读取概览', admin: true, invoke: (_, s, c) => s.loadOverview(session: c)),
  (name: '读取事件', admin: true, invoke: (_, s, c) => s.loadEvents(session: c)),
  (name: '读取封禁', admin: true, invoke: (_, s, c) => s.loadBlocks(session: c)),
  (
    name: '处置事件',
    admin: true,
    invoke: (_, s, c) async {
      await s.resolve(9, session: c);
      return true;
    }
  ),
  (
    name: '标记误报',
    admin: true,
    invoke: (_, s, c) async {
      await s.markFalsePositive(9, session: c);
      return true;
    }
  ),
  (
    name: '封禁来源',
    admin: true,
    invoke: (_, s, c) async {
      await s.createBlock(
          sourceKey: 'synthetic', durationMinutes: 15, session: c);
      return true;
    }
  ),
  (
    name: '解除封禁',
    admin: true,
    invoke: (_, s, c) async {
      await s.revokeBlock(9, session: c);
      return true;
    }
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    AppPreferencesStore.setMockInitialValues(
        {'push_installation_id': 'security-qa'});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'shenliyuan/grade_reminders',
      'shenliyuan/private_message_notifications',
      'shenliyuan/notification_open',
      'shenliyuan/keep_alive'
    ]) {
      messenger.setMockMethodCallHandler(
          MethodChannel(name), (_) async => true);
      addTearDown(
          () => messenger.setMockMethodCallHandler(MethodChannel(name), null));
    }
  });

  ({AuthProvider auth, _Credentials credentials, _Adapter adapter}) fixture() {
    final adapter = _Adapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
      ..httpClientAdapter = adapter;
    final credentials = _Credentials();
    final auth = AuthProvider(dio,
        credentialStore: credentials,
        loadStoredAuth: false,
        onAuthenticated: () {},
        sessionCleanupCoordinator: AccountSessionCleanupCoordinator());
    addTearDown(() {
      if (!adapter.releaseRefresh.isCompleted) {
        adapter.releaseRefresh.complete();
      }
      if (!adapter.releaseOperation.isCompleted) {
        adapter.releaseOperation.complete();
      }
      if (!adapter.releaseProfile.isCompleted) {
        adapter.releaseProfile.complete();
      }
      auth.dispose();
      dio.close(force: true);
    });
    return (auth: auth, credentials: credentials, adapter: adapter);
  }

  for (final op in _operations) {
    for (final switchAccount in [true, false]) {
      test('${op.name}等待真实刷新期间${switchAccount ? '切号阻断' : '同账号继续'}', () async {
        final f = fixture();
        expect((await f.auth.login('synthetic', 'synthetic-password')).success,
            isTrue);
        final scope = PublishSessionScope(
            accountId: 1, accountSessionEpoch: f.auth.accountSessionEpoch);
        final future = op
            .invoke(f.auth, AdminSecurityService(f.auth.dio), scope)
            .then<Object?>((value) => value, onError: (Object error) => error);
        await f.adapter.refreshStarted.future
            .timeout(const Duration(seconds: 5));
        if (switchAccount) await f.auth.applyAuthPayload('token-b', _user(2));
        f.adapter.releaseRefresh.complete();
        final result = await future;
        if (switchAccount) {
          expect(f.adapter.requests, isEmpty);
          expect(
              result,
              op.admin
                  ? isA<DioException>()
                  : op.name == '读取私有资料'
                      ? isNull
                      : isA<AuthResult>()
                          .having((r) => r.success, 'success', false));
          expect(f.auth.user?.id, 2);
          expect(f.credentials.stored.token, 'token-b');
        } else {
          expect(f.adapter.requests, hasLength(1));
          final request = f.adapter.requests.single;
          expect(request.headers['Authorization'], 'Bearer refreshed-a');
          expect(request.extra['expectedAuthUserId'], 1);
          expect(request.extra['expectedAuthSessionEpoch'],
              scope.accountSessionEpoch);
          expect(result, isNot(isA<Exception>()));
          if (result is AuthResult) expect(result.success, isTrue);
          expect(f.auth.user?.id, 1);
        }
      });
    }
  }

  for (final mode in ['刷新', '编辑', '主页编辑弹层']) {
    test('$mode资料响应不能覆盖已更新的邮箱绑定状态', () async {
      final f = fixture();
      await f.auth.applyAuthPayload('token-a', _user(1));
      f.adapter.holdProfile = true;
      f.adapter.updatedEmailBound = true;
      Future<void> applyFromEditor() async {
        final scope = PublishSessionScope(
            accountId: 1, accountSessionEpoch: f.auth.accountSessionEpoch);
        final response = await f.auth.dio.put('/user/profile',
            data: {'nickname': '新昵称'},
            options: Options(extra: scope.requestExtra));
        await f.auth.applyProfileResponse(
            Map<String, dynamic>.from(response.data),
            request: response.requestOptions);
      }

      final pending = switch (mode) {
        '编辑' => f.auth.updateProfile('新昵称'),
        '主页编辑弹层' => applyFromEditor(),
        _ => f.auth.refreshUser(),
      };
      await f.adapter.profileStarted.future;
      expect(
          (await f.auth.updateUserEmail(
                  email: 'synthetic@example.test',
                  code: '123456',
                  password: 'synthetic'))
              .success,
          isTrue);
      expect(f.auth.user?.emailBound, isTrue);
      f.adapter.releaseProfile.complete();
      await pending;
      expect(f.auth.user?.emailBound, isTrue);
      expect(jsonDecode(f.credentials.stored.userJson!)['email_bound'], isTrue);
      expect(f.auth.token, 'updated-a');
    });
  }

  for (final op in _operations
      .where((op) => ['换绑邮箱', '解除邮箱', '修改密码'].contains(op.name))) {
    test('${op.name}成功后迟到的旧刷新响应不能覆盖新凭据', () async {
      final f = fixture();
      f.adapter.loginMinutes = 60;
      expect((await f.auth.login('synthetic', 'synthetic-password')).success,
          isTrue);
      final epoch = f.auth.accountSessionEpoch;
      final scope =
          PublishSessionScope(accountId: 1, accountSessionEpoch: epoch);
      f.adapter.holdOperation = true;
      final operation =
          op.invoke(f.auth, AdminSecurityService(f.auth.dio), scope);
      await f.adapter.operationStarted.future;
      final refresh = f.auth.refreshSession();
      await f.adapter.refreshStarted.future;
      f.adapter.releaseOperation.complete();
      expect(((await operation)! as AuthResult).success, isTrue);
      f.adapter.releaseRefresh.complete();
      expect(await refresh, isFalse);
      expect(f.auth.token, 'updated-a');
      expect(f.credentials.stored.token, 'updated-a');
      expect(f.auth.accountSessionEpoch, epoch);
    });
    for (final exit in ['切号', '退出', '持久化期间切号', '响应用户错误', '存储失败']) {
      test('${op.name}$exit 后旧成功响应不能覆盖当前会话', () async {
        final f = fixture();
        await f.auth.applyAuthPayload('token-a', _user(1));
        f.adapter.holdOperation = true;
        final scope = PublishSessionScope(
            accountId: 1, accountSessionEpoch: f.auth.accountSessionEpoch);
        final future =
            op.invoke(f.auth, AdminSecurityService(f.auth.dio), scope);
        await f.adapter.operationStarted.future;
        if (exit == '切号') await f.auth.applyAuthPayload('token-b', _user(2));
        if (exit == '退出') await f.auth.logout();
        if (exit == '响应用户错误') f.adapter.responseUser = 2;
        if (exit == '存储失败') f.credentials.failWrite = true;
        if (exit == '持久化期间切号') {
          f.credentials.writeStarted = Completer<void>();
          f.credentials.releaseWrite = Completer<void>();
        }
        f.adapter.releaseOperation.complete();
        if (exit == '持久化期间切号') {
          await f.credentials.writeStarted!.future;
          final switchFuture = f.auth.applyAuthPayload('token-b', _user(2));
          f.credentials.releaseWrite!.complete();
          await switchFuture;
        }
        final result = (await future)! as AuthResult;
        expect(result.success, isFalse);
        final expectedId = exit == '退出'
            ? null
            : exit.contains('切号')
                ? 2
                : 1;
        expect(f.auth.user?.id, expectedId);
        expect(
            f.auth.token,
            expectedId == null
                ? null
                : expectedId == 2
                    ? 'token-b'
                    : 'token-a');
        expect(
            f.credentials.stored.token,
            expectedId == null
                ? null
                : expectedId == 2
                    ? 'token-b'
                    : 'token-a');
      });
    }
  }
}
