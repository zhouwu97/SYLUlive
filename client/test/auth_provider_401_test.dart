import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';

/// 按序返回预设响应的 HttpClientAdapter。
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

/// 可把某个请求挂起、直到测试释放其响应的适配器，用于模拟“旧请求晚返回”。
class _HoldableQueuedAdapter implements HttpClientAdapter {
  final List<({int statusCode, Object? data})> _responses = [];
  Completer<void>? _hold;
  Completer<void>? _heldSignal;

  void enqueue(int statusCode, Object? data) {
    _responses.add((statusCode: statusCode, data: data));
  }

  /// 让下一个 fetch 在返回预设响应前一直等待，直到 [release]。
  void holdNext() {
    _hold = Completer<void>();
    _heldSignal = Completer<void>();
  }

  /// 请求已进入挂起态（onRequest 已执行、凭据上下文已被请求捕获）时完成。
  Future<void> get held => _heldSignal?.future ?? Future<void>.value();

  void release() {
    final hold = _hold;
    _hold = null;
    hold?.complete();
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
    final hold = _hold;
    if (hold != null) {
      _heldSignal?.complete();
      await hold.future;
    }
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
  int writeCount = 0;
  int clearCount = 0;

  @override
  Future<StoredAuthCredentials> read() async => stored;

  @override
  Future<void> write({required String token, required String userJson}) async {
    writeCount++;
    stored = StoredAuthCredentials(token: token, userJson: userJson);
  }

  @override
  Future<void> clear() async {
    clearCount++;
    stored = const StoredAuthCredentials();
  }
}

/// 阻塞下一次 clear，直到测试释放；用于验证“清理过程中重新登录保留新会话”。
class _BlockingClearStore extends _FakeAuthCredentialStore {
  final Completer<void> clearStarted = Completer<void>();
  final Completer<void> releaseClear = Completer<void>();
  bool blockNextClear = false;

  @override
  Future<void> clear() async {
    if (blockNextClear) {
      blockNextClear = false;
      clearStarted.complete();
      await releaseClear.future;
    }
    super.clear();
  }
}

Future<void> _ignoreError(Future<dynamic> future) {
  return future.then<void>((_) {}, onError: (Object _, StackTrace __) {});
}

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
  messenger.setMockMethodCallHandler(
    const MethodChannel('shenliyuan/notification_open'),
    (_) async => true,
  );
  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
  });

  AuthProvider makeProvider(HttpClientAdapter adapter,
      {AuthCredentialStore? store}) {
    final dio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
      ..httpClientAdapter = adapter;
    return AuthProvider(
      dio,
      credentialStore: store ?? _FakeAuthCredentialStore(),
      loadStoredAuth: false,
      onAuthenticated: () {},
    );
  }

  group('非终结 401 一律不清除会话', () {
    test('401 无 code（旧服务端业务错误）不退出', () async {
      final adapter = _QueuedAuthAdapter()..enqueue(401, {'error': 'APP 密码错误'});
      final provider = makeProvider(adapter);
      await provider.applyAuthPayload('token', _userJson(1));
      final generation = provider.sessionGeneration;

      await _ignoreError(provider.dio.get('/protected'));
      await pumpEventQueue(times: 20);

      expect(provider.token, 'token');
      expect(provider.authState, AuthState.authenticated);
      expect(provider.sessionGeneration, generation);
    });

    test('401 code=INVALID_PASSWORD（密码类业务错误）不退出', () async {
      final adapter = _QueuedAuthAdapter()
        ..enqueue(401, {'code': 'INVALID_PASSWORD', 'error': 'APP 密码错误'});
      final provider = makeProvider(adapter);
      await provider.applyAuthPayload('token', _userJson(1));
      final generation = provider.sessionGeneration;

      await _ignoreError(provider.dio.get('/protected'));
      await pumpEventQueue(times: 20);

      expect(provider.token, 'token');
      expect(provider.sessionGeneration, generation);
    });

    test('/edu/* 返回终结 401 也不退出 App', () async {
      final adapter = _QueuedAuthAdapter()
        ..enqueue(401, {'code': 'invalid_token', 'error': '教务会话失效'});
      final provider = makeProvider(adapter);
      await provider.applyAuthPayload('token', _userJson(1));
      final generation = provider.sessionGeneration;

      await _ignoreError(provider.dio.get('/edu/refresh'));
      await pumpEventQueue(times: 20);

      expect(provider.token, 'token');
      expect(provider.sessionGeneration, generation);
    });
  });

  group('终结 401 才退出，且必须绑定当前会话', () {
    for (final code in ['invalid_token', 'token_version_expired', 'role_changed']) {
      test('当前会话收到 $code 正确退出', () async {
        final adapter = _QueuedAuthAdapter()
          ..enqueue(401, {'code': code, 'error': '凭据失效'});
        final provider = makeProvider(adapter);
        await provider.applyAuthPayload('token', _userJson(1));
        final generation = provider.sessionGeneration;

        await _ignoreError(provider.dio.get('/protected'));
        await pumpEventQueue(times: 20);

        expect(provider.token, isNull);
        expect(provider.user, isNull);
        expect(provider.authState, AuthState.guest);
        expect(provider.sessionGeneration, generation + 1);
      });
    }

    test('旧 Token 请求的终结 401 不能删除新会话', () async {
      final adapter = _HoldableQueuedAdapter()
        ..enqueue(401, {'code': 'token_version_expired', 'error': 'x'});
      final provider = makeProvider(adapter);
      await provider.applyAuthPayload('old-token', _userJson(1));

      adapter.holdNext();
      final requestFuture = provider.dio.get('/protected');
      await adapter.held;
      // 请求已携带旧 Token 发出，响应还在路上时，会话已切换到新 Token（如教务绑定/改密）。
      await provider.applyAuthPayload('new-token', _userJson(2));
      adapter.release();

      await _ignoreError(requestFuture);
      await pumpEventQueue(times: 20);

      expect(provider.token, 'new-token');
      expect(provider.user?.id, 2);
      expect(provider.authState, AuthState.authenticated);
    });

    test('请求发出时无 Token，恢复登录后回来的终结 401 不能删除新会话', () async {
      final adapter = _HoldableQueuedAdapter()
        ..enqueue(401, {'code': 'authentication_required', 'error': 'x'});
      final provider = makeProvider(adapter);

      adapter.holdNext();
      final requestFuture = provider.dio.get('/protected');
      await adapter.held;
      // 请求发出时是 guest；响应返回前登录恢复完成。
      await provider.applyAuthPayload('token', _userJson(1));
      adapter.release();

      await _ignoreError(requestFuture);
      await pumpEventQueue(times: 20);

      expect(provider.token, 'token');
      expect(provider.authState, AuthState.authenticated);
    });
  });

  group('并发与异步竞态', () {
    test('20 个并发终结 401 只清理一次会话', () async {
      final adapter = _QueuedAuthAdapter();
      final store = _FakeAuthCredentialStore();
      final provider = makeProvider(adapter, store: store);
      await provider.applyAuthPayload('token', _userJson(1));
      for (var i = 0; i < 20; i++) {
        adapter.enqueue(401, {'code': 'invalid_token', 'error': 'x'});
      }

      await Future.wait([
        for (var i = 0; i < 20; i++) _ignoreError(provider.dio.get('/p$i')),
      ]);
      await pumpEventQueue(times: 50);

      expect(store.clearCount, 1);
      expect(provider.token, isNull);
      expect(provider.authState, AuthState.guest);
    });

    test('清理过程中重新登录，最终保留新会话', () async {
      final adapter = _QueuedAuthAdapter();
      final store = _BlockingClearStore();
      final provider = makeProvider(adapter, store: store);
      await provider.applyAuthPayload('old-token', _userJson(1));

      adapter.enqueue(401, {'code': 'invalid_token', 'error': 'x'});
      store.blockNextClear = true;
      await _ignoreError(provider.dio.get('/protected'));
      await store.clearStarted.future;

      adapter.enqueue(200, {'token': 'new-token', 'user': _userJson(2)});
      final loginFuture = provider.login('account', 'password');
      await pumpEventQueue(times: 20);
      store.releaseClear.complete();
      final result = await loginFuture;
      await pumpEventQueue(times: 20);

      expect(result.success, isTrue, reason: result.errorMessage);
      expect(provider.token, 'new-token');
      expect(provider.user?.id, 2);
      expect(provider.authState, AuthState.authenticated);
    });
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
