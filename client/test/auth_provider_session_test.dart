import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/providers/auth_provider.dart';

class _QueuedAuthAdapter implements HttpClientAdapter {
  final List<({int statusCode, Object? data})> _responses = [];

  void enqueue(int statusCode, Object? data) {
    _responses.add((statusCode: statusCode, data: data));
  }

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    if (_responses.isEmpty) throw StateError('缺少认证响应: ${options.path}');
    final response = _responses.removeAt(0);
    return ResponseBody.fromString(
      jsonEncode(response.data),
      response.statusCode,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

class _FakeAuthCredentialStore implements AuthCredentialStore {
  StoredAuthCredentials stored = const StoredAuthCredentials();
  bool failWrites = false;
  bool failClear = false;
  int writeCount = 0;
  int clearCount = 0;

  @override
  Future<StoredAuthCredentials> read() async => stored;

  @override
  Future<void> write({required String token, required String userJson}) async {
    if (failWrites) throw StateError('auth write failed');
    writeCount++;
    stored = StoredAuthCredentials(token: token, userJson: userJson);
  }

  @override
  Future<void> clear() async {
    if (failClear) throw StateError('auth clear failed');
    clearCount++;
    stored = const StoredAuthCredentials();
  }

  @override
  Future<void> writeEduPassword(String studentId, String password) async {}
}

typedef _AuthInvocation = Future<AuthResult> Function(AuthProvider provider);

class _AuthCase {
  final String name;
  final int statusCode;
  final _AuthInvocation invoke;

  const _AuthCase(this.name, this.statusCode, this.invoke);
}

final _authCases = <_AuthCase>[
  _AuthCase(
    'register',
    201,
    (provider) => provider.register('20260001', 'password'),
  ),
  _AuthCase(
    'login',
    200,
    (provider) => provider.login('20260001', 'password'),
  ),
  _AuthCase(
    'loginEdu',
    200,
    (provider) => provider.loginEdu('20260001', 'edu-pass', 'password'),
  ),
  _AuthCase(
    'registerWithEdu',
    201,
    (provider) => provider.registerWithEdu(
      '20260001',
      'password',
      eduPassword: 'edu-pass',
    ),
  ),
  _AuthCase(
    'registerGraduate',
    201,
    (provider) => provider.registerGraduate(
      '10000',
      '123456',
      'password',
    ),
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('shenliyuan/grade_reminders'),
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('shenliyuan/private_message_notifications'),
    (_) async => null,
  );

  for (final authCase in _authCases) {
    test('${authCase.name} 的畸形用户响应不改变已有认证会话', () async {
      final adapter = _QueuedAuthAdapter()
        ..enqueue(authCase.statusCode, {
          'token': 'next-token',
          'user': {'id': 'not-an-integer'},
        });
      final store = _FakeAuthCredentialStore();
      final provider = _provider(adapter, store);
      await provider.applyAuthPayload('old-token', _userJson(1));
      final generation = provider.sessionGeneration;

      final result = await authCase.invoke(provider);

      expect(result.success, isFalse);
      expect(provider.token, 'old-token');
      expect(provider.user?.id, 1);
      expect(provider.sessionGeneration, generation);
      expect(provider.dio.options.headers['Authorization'], 'Bearer old-token');
    });

    test('${authCase.name} 的合法成功响应只递增一次认证代次', () async {
      final adapter = _QueuedAuthAdapter()
        ..enqueue(authCase.statusCode, {
          'token': 'next-token',
          'user': _userJson(2),
        });
      final store = _FakeAuthCredentialStore();
      final provider = _provider(adapter, store);
      await provider.applyAuthPayload('old-token', _userJson(1));
      final generation = provider.sessionGeneration;

      final result = await authCase.invoke(provider);

      expect(result.success, isTrue);
      expect(provider.token, 'next-token');
      expect(provider.user?.id, 2);
      expect(provider.sessionGeneration, generation + 1);
      expect(
          provider.dio.options.headers['Authorization'], 'Bearer next-token');
    });
  }

  test('applyAuthPayload 先完整解析用户，失败时不改变已有认证会话', () async {
    final provider = _provider(
      _QueuedAuthAdapter(),
      _FakeAuthCredentialStore(),
    );
    await provider.applyAuthPayload('old-token', _userJson(1));
    final generation = provider.sessionGeneration;

    await expectLater(
      provider.applyAuthPayload('next-token', {'id': 'not-an-integer'}),
      throwsA(isA<TypeError>()),
    );

    expect(provider.token, 'old-token');
    expect(provider.user?.id, 1);
    expect(provider.sessionGeneration, generation);
    expect(provider.dio.options.headers['Authorization'], 'Bearer old-token');
  });

  test('applyAuthPayload 持久化失败时不改变已有认证会话', () async {
    final store = _FakeAuthCredentialStore();
    final provider = _provider(_QueuedAuthAdapter(), store);
    await provider.applyAuthPayload('old-token', _userJson(1));
    final generation = provider.sessionGeneration;
    store.failWrites = true;

    await expectLater(
      provider.applyAuthPayload('next-token', _userJson(2)),
      throwsA(isA<StateError>()),
    );

    expect(provider.token, 'old-token');
    expect(provider.user?.id, 1);
    expect(provider.sessionGeneration, generation);
    expect(provider.dio.options.headers['Authorization'], 'Bearer old-token');
  });

  test('applyAuthPayload 合法成功只递增一次认证代次', () async {
    final provider = _provider(
      _QueuedAuthAdapter(),
      _FakeAuthCredentialStore(),
    );

    await provider.applyAuthPayload('token', _userJson(1));

    expect(provider.sessionGeneration, 1);
  });

  test('本地认证用户数据畸形时不恢复部分会话', () async {
    final store = _FakeAuthCredentialStore()
      ..stored = const StoredAuthCredentials(
        token: 'stored-token',
        userJson: '{"id":"not-an-integer"}',
      );
    final provider = _provider(
      _QueuedAuthAdapter(),
      store,
      loadStoredAuth: false,
    );

    await provider.initializeStoredAuth();

    expect(provider.isInitialized, isTrue);
    expect(provider.token, isNull);
    expect(provider.user, isNull);
    expect(provider.sessionGeneration, 0);
  });

  test('合法本地认证只递增一次认证代次', () async {
    final store = _FakeAuthCredentialStore()
      ..stored = StoredAuthCredentials(
        token: 'stored-token',
        userJson: jsonEncode(_userJson(1)),
      );
    final provider = _provider(
      _QueuedAuthAdapter(),
      store,
      loadStoredAuth: false,
    );

    await provider.initializeStoredAuth();

    expect(provider.token, 'stored-token');
    expect(provider.user?.id, 1);
    expect(provider.sessionGeneration, 1);
  });

  test('清除持久化失败时不改变已有认证会话', () async {
    final adapter = _QueuedAuthAdapter()..enqueue(200, {'success': true});
    final store = _FakeAuthCredentialStore();
    final provider = _provider(adapter, store);
    await provider.applyAuthPayload('old-token', _userJson(1));
    final generation = provider.sessionGeneration;
    store.failClear = true;

    await expectLater(provider.logout(), throwsA(isA<StateError>()));

    expect(provider.token, 'old-token');
    expect(provider.user?.id, 1);
    expect(provider.sessionGeneration, generation);
    expect(provider.dio.options.headers['Authorization'], 'Bearer old-token');
  });

  test('合法清除会话只递增一次认证代次', () async {
    final adapter = _QueuedAuthAdapter()..enqueue(200, {'success': true});
    final provider = _provider(adapter, _FakeAuthCredentialStore());
    await provider.applyAuthPayload('old-token', _userJson(1));
    final generation = provider.sessionGeneration;

    await provider.logout();

    expect(provider.token, isNull);
    expect(provider.user, isNull);
    expect(provider.sessionGeneration, generation + 1);
  });
}

AuthProvider _provider(
  _QueuedAuthAdapter adapter,
  AuthCredentialStore store, {
  bool loadStoredAuth = false,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
    ..httpClientAdapter = adapter;
  return AuthProvider(
    dio,
    credentialStore: store,
    loadStoredAuth: loadStoredAuth,
    onAuthenticated: () {},
  );
}

Map<String, dynamic> _userJson(int id) {
  return {
    'id': id,
    'student_id': '2026000$id',
    'nickname': '用户$id',
    'created_at': '2026-07-13T10:00:00Z',
  };
}
