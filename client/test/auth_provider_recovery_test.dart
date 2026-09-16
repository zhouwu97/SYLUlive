import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/providers/auth_provider.dart';

class _MockDioAdapter implements HttpClientAdapter {
  bool shouldFail = false;
  int fetchCount = 0;
  RequestOptions? lastOptions;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    fetchCount++;
    lastOptions = options;
    await requestStream?.drain<void>();

    if (shouldFail) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionTimeout,
        error: 'Connection timed out',
      );
    }

    return ResponseBody.fromString(
      jsonEncode({
        'token': 'access-after-refresh',
        'expires_at':
            DateTime.now().add(const Duration(minutes: 30)).toIso8601String(),
        'refresh_token': 'refresh-after-refresh',
        'refresh_expires_at':
            DateTime.now().add(const Duration(days: 30)).toIso8601String(),
        'user': _userJson,
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json']
      },
    );
  }
}

class _FlakySessionStore implements SessionAuthCredentialStore {
  StoredAuthCredentials stored;
  int readAttempts = 0;
  int failReadCount;
  bool wasCleared = false;

  _FlakySessionStore(this.stored, {this.failReadCount = 0});

  @override
  Future<StoredAuthCredentials> read() async {
    readAttempts++;
    if (readAttempts <= failReadCount) {
      throw Exception('Secure storage temporary Keystore error');
    }
    return stored;
  }

  @override
  Future<void> write({required String token, required String userJson}) async {
    stored = StoredAuthCredentials(token: token, userJson: userJson);
  }

  @override
  Future<void> writeSession({
    required String token,
    required String userJson,
    String? refreshToken,
    DateTime? accessTokenExpiresAt,
    DateTime? refreshTokenExpiresAt,
  }) async {
    stored = StoredAuthCredentials(
      token: token,
      userJson: userJson,
      refreshToken: refreshToken,
      accessTokenExpiresAt: accessTokenExpiresAt,
      refreshTokenExpiresAt: refreshTokenExpiresAt,
    );
  }

  @override
  Future<void> clear() async {
    wasCleared = true;
    stored = const StoredAuthCredentials();
  }
}

const _userJson = <String, dynamic>{
  'id': 100,
  'student_id': '20260100',
  'nickname': '测试用户',
  'created_at': '2026-07-13T10:00:00Z',
  'legal_consents_active': true,
  'legal_consents_required': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('冷启动网络异常与安全存储重试闭环', () {
    test('Access Token已过期但Refresh Token有效，冷启动网络超时不得清除凭据且进入可恢复状态', () async {
      final adapter = _MockDioAdapter()..shouldFail = true;
      final store = _FlakySessionStore(
        StoredAuthCredentials(
          token: 'expired-access-token',
          refreshToken: 'valid-refresh-token',
          accessTokenExpiresAt:
              DateTime.now().subtract(const Duration(minutes: 5)),
          refreshTokenExpiresAt: DateTime.now().add(const Duration(days: 20)),
          userJson: jsonEncode(_userJson),
        ),
      );
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
        ..httpClientAdapter = adapter;

      final provider = AuthProvider(
        dio,
        credentialStore: store,
        loadStoredAuth: false,
        onAuthenticated: () {},
      );

      await provider.initializeStoredAuth();

      // 验证未被误判为 guest，没有清除凭据
      expect(store.wasCleared, isFalse);
      expect(provider.authState, AuthState.recoveryFailed);
      expect(provider.isLoggedIn, isFalse);
      expect(provider.hasRecoverableSession, isTrue);
      expect(provider.user?.id, 100);
      expect(store.stored.refreshToken, 'valid-refresh-token');

      // 验证网络恢复后再次 refresh 成功，恢复为 authenticated
      adapter.shouldFail = false;
      final refreshed = await provider.refreshSession();
      expect(refreshed, isTrue);
      expect(provider.authState, AuthState.authenticated);
      expect(provider.isLoggedIn, isTrue);
      expect(provider.hasRecoverableSession, isFalse);
      expect(provider.token, 'access-after-refresh');
      expect(store.stored.refreshToken, 'refresh-after-refresh');
    });

    test('Secure Store 第一次 read 抛异常，300ms 内部重试成功后恢复登录状态', () async {
      final adapter = _MockDioAdapter();
      final store = _FlakySessionStore(
        StoredAuthCredentials(
          token: 'valid-access-token',
          refreshToken: 'valid-refresh-token',
          accessTokenExpiresAt: DateTime.now().add(const Duration(hours: 1)),
          refreshTokenExpiresAt: DateTime.now().add(const Duration(days: 20)),
          userJson: jsonEncode(_userJson),
        ),
        failReadCount: 1, // 第一次抛出异常，第二次成功
      );
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
        ..httpClientAdapter = adapter;

      final provider = AuthProvider(
        dio,
        credentialStore: store,
        loadStoredAuth: false,
        onAuthenticated: () {},
      );

      await provider.initializeStoredAuth();

      expect(store.readAttempts, 2);
      expect(store.wasCleared, isFalse);
      expect(provider.authState, AuthState.authenticated);
      expect(provider.isLoggedIn, isTrue);
      expect(provider.user?.id, 100);
    });

    test('Secure Store 持续抛异常时进入 recoveryFailed 而非 guest，且不清除凭据', () async {
      final adapter = _MockDioAdapter();
      final store = _FlakySessionStore(
        StoredAuthCredentials(
          token: 'valid-access-token',
          refreshToken: 'valid-refresh-token',
          accessTokenExpiresAt: DateTime.now().add(const Duration(hours: 1)),
          refreshTokenExpiresAt: DateTime.now().add(const Duration(days: 20)),
          userJson: jsonEncode(_userJson),
        ),
        failReadCount: 5, // 两次都抛出异常
      );
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
        ..httpClientAdapter = adapter;

      final provider = AuthProvider(
        dio,
        credentialStore: store,
        loadStoredAuth: false,
        onAuthenticated: () {},
      );

      await provider.initializeStoredAuth();

      expect(store.readAttempts, 2);
      expect(store.wasCleared, isFalse);
      expect(provider.authState, AuthState.recoveryFailed);
      expect(provider.isLoggedIn, isFalse);
      // 凭据仍在 store 中
      expect(store.stored.token, 'valid-access-token');
    });
  });
}
