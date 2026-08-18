import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
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

/// 使用真实平台凭据存储（AppSecretStore + AppPreferencesStore）构造 AuthProvider，
/// 墓碑读写只在平台路径下生效，因此墓碑回归测试必须走这里。
AuthProvider _platformProvider(HttpClientAdapter adapter,
    {required bool loadStoredAuth}) {
  final dio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
    ..httpClientAdapter = adapter;
  return AuthProvider(
    dio,
    loadStoredAuth: loadStoredAuth,
    onAuthenticated: () {},
  );
}

Future<void> _ignoreError(Future<dynamic> future) {
  return future.then<void>((_) {}, onError: (Object _, StackTrace __) {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final secureStore = <String, String>{};
  late String tempRoot;

  setUpAll(() async {
    tempRoot = (await Directory.systemTemp.createTemp('auth_tombstone_test_'))
        .path;
  });

  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
    secureStore.clear();
    messenger.setMockMethodCallHandler(pathProviderChannel, (call) async {
      switch (call.method) {
        case 'getTemporaryDirectory':
        case 'getApplicationSupportDirectory':
        case 'getApplicationDocumentsDirectory':
          return tempRoot;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(secureStorageChannel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return secureStore[key];
        case 'write':
          secureStore[key!] = args['value'] as String;
          return null;
        case 'delete':
          secureStore.remove(key);
          return null;
        case 'deleteAll':
          secureStore.clear();
          return null;
        case 'containsKey':
          return secureStore.containsKey(key);
        case 'readAll':
          return secureStore;
      }
      return null;
    });
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
      (_) async => true,
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(secureStorageChannel, null);
    messenger.setMockMethodCallHandler(pathProviderChannel, null);
  });

  test('冷启动发现退出墓碑时进入 guest 并清除墓碑，重复冷启动不再随机登录', () async {
    AppPreferencesStore.setMockInitialValues({'auth_force_logged_out': true});
    final provider = _platformProvider(_QueuedAuthAdapter(), loadStoredAuth: true);

    await provider.initializeStoredAuth();

    expect(provider.authState, AuthState.guest);
    expect(provider.token, isNull);
    final prefs = await AppPreferencesStore.getInstance();
    expect(prefs.getBool('auth_force_logged_out'), isNot(true));

    // 再次冷启动：墓碑已删、无凭据 → 仍然是 guest，不出现随机登录。
    final second =
        _platformProvider(_QueuedAuthAdapter(), loadStoredAuth: true);
    await second.initializeStoredAuth();
    expect(second.authState, AuthState.guest);
    expect(second.token, isNull);
  });

  test('手动退出后重新登录，重启仍是登录态（墓碑被新会话清除）', () async {
    final adapter = _QueuedAuthAdapter();
    final provider = _platformProvider(adapter, loadStoredAuth: false);

    adapter.enqueue(200, {'token': 'token-1', 'user': _userJson(1)});
    final first = await provider.login('account', 'password');
    expect(first.success, isTrue, reason: first.errorMessage);
    expect(provider.authState, AuthState.authenticated);

    adapter.enqueue(200, {'success': true});
    await provider.logout();
    expect(provider.authState, AuthState.guest);
    final afterLogout = await AppPreferencesStore.getInstance();
    expect(afterLogout.getBool('auth_force_logged_out'), isTrue);

    adapter.enqueue(200, {'token': 'token-2', 'user': _userJson(1)});
    final second = await provider.login('account', 'password');
    expect(second.success, isTrue, reason: second.errorMessage);
    final afterRelogin = await AppPreferencesStore.getInstance();
    expect(afterRelogin.getBool('auth_force_logged_out'), isNot(true));

    final restarted =
        _platformProvider(_QueuedAuthAdapter(), loadStoredAuth: true);
    await restarted.initializeStoredAuth();
    expect(restarted.authState, AuthState.authenticated);
    expect(restarted.token, 'token-2');
  });

  test('401 强制退出后重新登录，重启不再落入 guest', () async {
    final adapter = _QueuedAuthAdapter();
    final provider = _platformProvider(adapter, loadStoredAuth: false);

    adapter.enqueue(200, {'token': 'token-1', 'user': _userJson(1)});
    final first = await provider.login('account', 'password');
    expect(first.success, isTrue, reason: first.errorMessage);

    adapter.enqueue(401, {'code': 'invalid_token', 'error': '凭据失效'});
    await _ignoreError(provider.dio.get('/protected'));
    await pumpEventQueue(times: 30);
    expect(provider.authState, AuthState.guest);
    final afterExpiry = await AppPreferencesStore.getInstance();
    expect(afterExpiry.getBool('auth_force_logged_out'), isTrue);

    adapter.enqueue(200, {'token': 'token-2', 'user': _userJson(1)});
    final second = await provider.login('account', 'password');
    expect(second.success, isTrue, reason: second.errorMessage);
    final afterRelogin = await AppPreferencesStore.getInstance();
    expect(afterRelogin.getBool('auth_force_logged_out'), isNot(true));

    final restarted =
        _platformProvider(_QueuedAuthAdapter(), loadStoredAuth: true);
    await restarted.initializeStoredAuth();
    expect(restarted.authState, AuthState.authenticated);
    expect(restarted.token, 'token-2');
  });
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
