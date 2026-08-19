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
  final List<String> operations = [];
  bool failWrites = false;
  bool failClear = false;
  int writeCount = 0;
  int clearCount = 0;

  @override
  Future<StoredAuthCredentials> read() async => stored;

  @override
  Future<void> write({required String token, required String userJson}) async {
    operations.add('auth:write:$token');
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
}

class _BlockingAuthCredentialStore extends _FakeAuthCredentialStore {
  final Completer<void> staleWriteStarted = Completer<void>();
  final Completer<void> releaseStaleWrite = Completer<void>();
  bool blockNextWrite = false;

  @override
  Future<void> write({required String token, required String userJson}) async {
    operations.add('auth:write:$token');
    if (failWrites) throw StateError('auth write failed');
    writeCount++;
    if (blockNextWrite) {
      blockNextWrite = false;
      staleWriteStarted.complete();
      await releaseStaleWrite.future;
    }
    stored = StoredAuthCredentials(token: token, userJson: userJson);
  }
}

class _FakePreferenceStore implements PreferenceStore {
  final Map<String, String> values = {};
  final Map<String, List<bool>> setResults = {};
  final Map<String, List<bool>> removeResults = {};

  @override
  String? getString(String key) => values[key];

  @override
  Future<bool> setString(String key, String value) async {
    final result = _nextResult(setResults, key);
    if (result) values[key] = value;
    return result;
  }

  @override
  Future<bool> remove(String key) async {
    final result = _nextResult(removeResults, key);
    if (result) values.remove(key);
    return result;
  }

  bool _nextResult(Map<String, List<bool>> results, String key) {
    final queued = results[key];
    if (queued == null || queued.isEmpty) return true;
    return queued.removeAt(0);
  }
}

typedef _AuthInvocation = Future<AuthResult> Function(AuthProvider provider);

const _registrationConsents = RegistrationConsents(
  userAgreementAccepted: true,
  privacyPolicyAccepted: true,
  communityRulesAccepted: true,
  minorProtectionAccepted: true,
  contentComplaintAccepted: true,
  sdkDisclosureAccepted: true,
  eduDataConsentAccepted: true,
);

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
    (provider) => provider.register(
      '20260001',
      'password',
      consents: _registrationConsents,
    ),
  ),
  _AuthCase(
    'login',
    200,
    (provider) => provider.login('20260001', 'password'),
  ),
  _AuthCase(
    'registerWithEdu',
    201,
    (provider) => provider.registerWithEdu(
      '20260001',
      'password',
      eduPassword: 'edu-pass',
      consents: _registrationConsents,
    ),
  ),
  _AuthCase(
    'registerWithEmail',
    201,
    (provider) => provider.registerWithEmail(
      'user@example.com',
      '123456',
      'password',
      consents: _registrationConsents,
    ),
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final notificationOpenCalls = <MethodCall>[];
  messenger.setMockMethodCallHandler(
    const MethodChannel('shenliyuan/grade_reminders'),
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('shenliyuan/private_message_notifications'),
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('shenliyuan/notification_open'),
    (call) async {
      notificationOpenCalls.add(call);
      return true;
    },
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

  test('Web 认证 user 写入 false 时回滚已写入的 token', () async {
    final preferences = _FakePreferenceStore();
    final store = PreferenceAuthCredentialStore(preferences);
    final provider = _provider(_QueuedAuthAdapter(), store);
    await provider.applyAuthPayload('old-token', _userJson(1));
    final generation = provider.sessionGeneration;
    preferences.setResults['auth_user'] = [false];

    await expectLater(
      provider.applyAuthPayload('next-token', _userJson(2)),
      throwsA(isA<StateError>()),
    );

    _expectOldPreferenceSession(provider, preferences, generation);
  });

  test('Web 认证部分写失败且回滚 false 时抛一致性错误且不提交内存', () async {
    final preferences = _FakePreferenceStore();
    final store = PreferenceAuthCredentialStore(preferences);
    final provider = _provider(_QueuedAuthAdapter(), store);
    await provider.applyAuthPayload('old-token', _userJson(1));
    final generation = provider.sessionGeneration;
    preferences.setResults['auth_token'] = [true, false];
    preferences.setResults['auth_user'] = [false];

    await expectLater(
      provider.applyAuthPayload('next-token', _userJson(2)),
      throwsA(
        isA<AuthCredentialConsistencyException>().having(
          (error) => error.message,
          'message',
          contains('回滚认证信息失败'),
        ),
      ),
    );

    expect(provider.token, 'old-token');
    expect(provider.user?.id, 1);
    expect(provider.sessionGeneration, generation);
    expect(provider.dio.options.headers['Authorization'], 'Bearer old-token');
  });

  test('Web 新会话部分写失败且回滚 remove false 时不提交内存', () async {
    final preferences = _FakePreferenceStore()
      ..setResults['auth_user'] = [false]
      ..removeResults['auth_token'] = [false];
    final store = PreferenceAuthCredentialStore(preferences);
    final provider = _provider(_QueuedAuthAdapter(), store);

    await expectLater(
      provider.applyAuthPayload('next-token', _userJson(2)),
      throwsA(isA<AuthCredentialConsistencyException>()),
    );

    expect(provider.token, isNull);
    expect(provider.user, isNull);
    expect(provider.sessionGeneration, 0);
    expect(provider.dio.options.headers['Authorization'], isNull);
  });

  test('Web 清理第二项 remove false 时恢复旧 token 和 user', () async {
    final preferences = _FakePreferenceStore()
      ..values['auth_token'] = 'old-token'
      ..values['auth_user'] = jsonEncode(_userJson(1))
      ..removeResults['auth_user'] = [false];
    final store = PreferenceAuthCredentialStore(preferences);

    await expectLater(store.clear(), throwsA(isA<StateError>()));

    expect(preferences.values['auth_token'], 'old-token');
    expect(jsonDecode(preferences.values['auth_user']!)['id'], 1);
  });

  test('Web 凭据合法写入和删除均成功', () async {
    final preferences = _FakePreferenceStore();
    final store = PreferenceAuthCredentialStore(preferences);

    await store.write(
      token: 'token',
      userJson: jsonEncode(_userJson(1)),
    );

    expect(preferences.values['auth_token'], 'token');
    expect(jsonDecode(preferences.values['auth_user']!)['id'], 1);
  });

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

  test('旧资料刷新提交期间，旧编辑入口最终保留更新后的资料', () async {
    final adapter = _QueuedAuthAdapter()
      ..enqueue(200, _userJson(2))
      ..enqueue(200, _userJson(3));
    final store = _BlockingAuthCredentialStore();
    final provider = _provider(adapter, store);
    await provider.applyAuthPayload('token', _userJson(1));
    store.blockNextWrite = true;

    final staleRefresh = provider.refreshUser();
    await store.staleWriteStarted.future;
    final profileUpdate = provider.updateProfile('用户3');

    // 让 PUT 响应进入资料提交路径，但保留旧刷新写入的阻塞。
    await pumpEventQueue(times: 10);

    store.releaseStaleWrite.complete();
    await Future.wait([staleRefresh, profileUpdate]);

    expect(provider.user?.id, 3);
    expect(jsonDecode(store.stored.userJson!)['id'], 3);
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
    notificationOpenCalls.clear();

    await provider.logout();

    expect(provider.token, isNull);
    expect(provider.user, isNull);
    expect(provider.sessionGeneration, generation + 1);
    expect(
      notificationOpenCalls.map((call) => call.method),
      contains('clearPendingNotificationOpen'),
    );
  });

  test('确认新版协议后以服务端状态更新本地会话', () async {
    final adapter = _QueuedAuthAdapter()
      ..enqueue(200, {
        'user': {
          ..._userJson(1),
          'legal_consents_active': true,
          'legal_consents_required': false,
        },
      });
    final provider = _provider(adapter, _FakeAuthCredentialStore());
    await provider.applyAuthPayload('token', {
      ..._userJson(1),
      'legal_consents_active': false,
      'legal_consents_required': true,
    });

    final result = await provider.acceptRequiredLegalConsents(
      includeEduDataConsent: false,
    );

    expect(result.success, isTrue, reason: result.errorMessage);
    expect(provider.user?.legalConsentsActive, isTrue);
    expect(provider.user?.legalConsentsRequired, isFalse);
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
    'legal_consents_active': true,
    'legal_consents_required': false,
  };
}

void _expectOldPreferenceSession(
  AuthProvider provider,
  _FakePreferenceStore preferences,
  int generation,
) {
  expect(provider.token, 'old-token');
  expect(provider.user?.id, 1);
  expect(provider.sessionGeneration, generation);
  expect(provider.dio.options.headers['Authorization'], 'Bearer old-token');
  expect(preferences.values['auth_token'], 'old-token');
  expect(jsonDecode(preferences.values['auth_user']!)['id'], 1);
}
