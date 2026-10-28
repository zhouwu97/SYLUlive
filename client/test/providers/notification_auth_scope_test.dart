import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/services/account_session_cleanup_coordinator.dart';
import 'package:shenliyuan/services/publish_session_scope.dart';
import 'package:shenliyuan/services/reply_notification_service.dart';

class _Credentials implements AuthCredentialStore {
  StoredAuthCredentials stored = const StoredAuthCredentials();

  @override
  Future<StoredAuthCredentials> read() async => stored;

  @override
  Future<void> write({required String token, required String userJson}) async {
    stored = StoredAuthCredentials(token: token, userJson: userJson);
  }

  @override
  Future<void> clear() async {
    stored = const StoredAuthCredentials();
  }
}

Map<String, dynamic> _user(int id) => {
      'id': id,
      'nickname': '测试用户$id',
      'created_at': '2026-01-01T00:00:00Z',
      'legal_consents_active': true,
      'legal_consents_required': false,
    };

class _RefreshAdapter implements HttpClientAdapter {
  final refreshStarted = Completer<void>();
  final releaseRefresh = Completer<void>();
  final writes = <RequestOptions>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    Object body;
    switch (options.path) {
      case '/login':
        body = {
          'token': 'token-a',
          'refresh_token': 'refresh-a',
          'expires_at': DateTime.now()
              .add(const Duration(minutes: 1))
              .toUtc()
              .toIso8601String(),
          'user': _user(1),
        };
      case '/refresh':
        refreshStarted.complete();
        await releaseRefresh.future;
        body = {
          'token': 'token-a-refreshed',
          'refresh_token': 'refresh-a-next',
          'expires_at': DateTime.now()
              .add(const Duration(hours: 1))
              .toUtc()
              .toIso8601String(),
          'user': _user(1),
        };
      default:
        if (!options.path.startsWith('/notifications/')) {
          throw StateError('意外的测试请求：${options.path}');
        }
        writes.add(options);
        body = {'message': '已标记已读'};
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json']
      },
    );
  }
}

typedef _Write = Future<void> Function(
  ReplyNotificationService service,
  PublishSessionScope session,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppPreferencesStore.setMockInitialValues({
      'push_installation_id': 'notification-auth-scope-test',
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'shenliyuan/grade_reminders',
      'shenliyuan/private_message_notifications',
      'shenliyuan/notification_open',
      'shenliyuan/keep_alive',
    ]) {
      messenger.setMockMethodCallHandler(
          MethodChannel(name), (_) async => true);
      addTearDown(
          () => messenger.setMockMethodCallHandler(MethodChannel(name), null));
    }
  });

  final operations = <({String name, String path, _Write invoke})>[
    (
      name: '回复一键已读',
      path: '/notifications/replies/read',
      invoke: (service, session) =>
          service.markAllRead(repliesOnly: true, session: session),
    ),
    (
      name: '通知全部已读',
      path: '/notifications/read',
      invoke: (service, session) => service.markAllRead(session: session),
    ),
    (
      name: '单条已读',
      path: '/notifications/read-selected',
      invoke: (service, session) => service.markRead(91, session: session),
    ),
  ];

  for (final operation in operations) {
    for (final switchAccount in [true, false]) {
      test('${operation.name}等待真实令牌刷新时${switchAccount ? '切号阻断旧写入' : '同账号允许继续'}',
          () async {
        final adapter = _RefreshAdapter();
        final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
          ..httpClientAdapter = adapter;
        final credentials = _Credentials();
        final auth = AuthProvider(
          dio,
          credentialStore: credentials,
          loadStoredAuth: false,
          sessionCleanupCoordinator: AccountSessionCleanupCoordinator(),
          onAuthenticated: () {},
        );
        addTearDown(() {
          if (!adapter.releaseRefresh.isCompleted) {
            adapter.releaseRefresh.complete();
          }
          auth.dispose();
          dio.close(force: true);
        });
        expect(
            (await auth.login('account-a', 'synthetic-test-password')).success,
            isTrue);
        final session = PublishSessionScope(
          accountId: auth.user!.id,
          accountSessionEpoch: auth.accountSessionEpoch,
        );
        final write = operation.invoke(ReplyNotificationService(dio), session);
        final completion = switchAccount
            ? expectLater(
                write,
                throwsA(isA<DioException>().having(
                    (error) => error.type, 'type', DioExceptionType.cancel)))
            : expectLater(write, completes);

        // 经过真实 AuthProvider.onRequest，等待它的自动刷新 HTTP 到达适配器。
        await adapter.refreshStarted.future.timeout(const Duration(seconds: 5));
        expect(adapter.writes, isEmpty);
        if (switchAccount) {
          await auth.applyAuthPayload('token-b', _user(2));
        }
        adapter.releaseRefresh.complete();
        await completion;

        if (switchAccount) {
          expect(adapter.writes, isEmpty, reason: '旧已读操作不得以 B 凭据发往服务器');
          expect(auth.user?.id, 2);
          expect(auth.token, 'token-b');
          expect(credentials.stored.token, 'token-b');
        } else {
          expect(adapter.writes, hasLength(1));
          final request = adapter.writes.single;
          expect(request.path, operation.path);
          expect(request.headers['Authorization'], 'Bearer token-a-refreshed');
          expect(request.extra['expectedAuthUserId'], 1);
          expect(request.extra['expectedAuthSessionEpoch'],
              session.accountSessionEpoch);
          expect(auth.user?.id, 1);
          expect(auth.token, 'token-a-refreshed');
        }
      });
    }
  }
}
