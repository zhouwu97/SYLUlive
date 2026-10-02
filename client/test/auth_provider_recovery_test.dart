import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
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

/// 9.2.4 在 Android 上把 Java 堆栈放进 PlatformException.details，
/// code 固定为 "Exception encountered"，message 只是方法名。
PlatformException badDecryptPlatformException() => PlatformException(
      code: 'Exception encountered',
      message: 'read',
      details: 'javax.crypto.BadPaddingException: error:1e000065:Cipher '
          'functions:OPENSSL_internal:BAD_DECRYPT\n'
          '\tat com.it_nomads.fluttersecurestorage.ciphers.'
          'StorageCipher18Implementation.decrypt(StorageCipher18Implementation.java:57)\n'
          '\tat com.it_nomads.fluttersecurestorage.FlutterSecureStorage.read'
          '(FlutterSecureStorage.java:96)',
    );

class _FlakySessionStore implements SessionAuthCredentialStore {
  StoredAuthCredentials stored;
  int readAttempts = 0;
  int failReadCount;
  List<Object>? readErrors;
  Object? readException;
  bool wasCleared = false;

  _FlakySessionStore(this.stored, {this.failReadCount = 0});

  @override
  Future<StoredAuthCredentials> read() async {
    readAttempts++;
    final errors = readErrors;
    if (errors != null) {
      if (readAttempts <= errors.length) throw errors[readAttempts - 1];
      return stored;
    }
    if (readAttempts <= failReadCount) {
      throw readException ??
          Exception('Secure storage temporary Keystore error');
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

    test('Secure Store 首次 read 抛 BAD_DECRYPT 时清理认证凭据进入 guest，且可直接重新登录', () async {
      final adapter = _MockDioAdapter();
      final store = _FlakySessionStore(
        StoredAuthCredentials(
          token: 'corrupted-access-token',
          refreshToken: 'corrupted-refresh-token',
          accessTokenExpiresAt: DateTime.now().add(const Duration(hours: 1)),
          refreshTokenExpiresAt: DateTime.now().add(const Duration(days: 20)),
          userJson: jsonEncode(_userJson),
        ),
      )
        ..readException = badDecryptPlatformException()
        ..failReadCount = 5;
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
        ..httpClientAdapter = adapter;

      final provider = AuthProvider(
        dio,
        credentialStore: store,
        loadStoredAuth: false,
        onAuthenticated: () {},
      );

      await provider.initializeStoredAuth();

      // 永久性密文损坏不进入重试路径，直接清理并进入 guest。
      expect(store.readAttempts, 1);
      expect(store.wasCleared, isTrue);
      expect(provider.authState, AuthState.guest);
      expect(provider.isLoggedIn, isFalse);
      expect(provider.hasRecoverableSession, isFalse);

      // 清理后同一会话内重新登录即可建立新会话。
      final result = await provider.login('account', 'password');
      expect(result.success, isTrue, reason: result.errorMessage);
      expect(provider.authState, AuthState.authenticated);
      expect(provider.isLoggedIn, isTrue);
      expect(provider.token, 'access-after-refresh');
      expect(store.stored.token, 'access-after-refresh');
    });

    test('首次临时异常重试后遇到 BAD_DECRYPT 同样清理认证凭据', () async {
      final adapter = _MockDioAdapter();
      final store = _FlakySessionStore(
        StoredAuthCredentials(
          token: 'corrupted-access-token',
          refreshToken: 'corrupted-refresh-token',
          accessTokenExpiresAt: DateTime.now().add(const Duration(hours: 1)),
          refreshTokenExpiresAt: DateTime.now().add(const Duration(days: 20)),
          userJson: jsonEncode(_userJson),
        ),
      )
        ..readErrors = [
          PlatformException(
            code: 'Exception encountered',
            message: 'read',
            details: 'java.security.KeyStoreException: Keystore busy',
          ),
          badDecryptPlatformException(),
        ];
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
      expect(store.wasCleared, isTrue);
      expect(provider.authState, AuthState.guest);
    });

    test('临时存储故障进入恢复未决后，同进程重试可恢复登录', () async {
      final adapter = _MockDioAdapter();
      final store = _FlakySessionStore(
        StoredAuthCredentials(
          token: 'valid-access-token',
          refreshToken: 'valid-refresh-token',
          accessTokenExpiresAt: DateTime.now().add(const Duration(hours: 1)),
          refreshTokenExpiresAt: DateTime.now().add(const Duration(days: 20)),
          userJson: jsonEncode(_userJson),
        ),
        failReadCount: 2, // 冷启动两次读取都失败；同进程重试时已恢复
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

      // 第一次冷启动：临时故障未决，凭据未清理。
      expect(provider.authState, AuthState.recoveryFailed);
      expect(provider.hasPendingStorageRecovery, isTrue);
      expect(provider.hasRecoverableSession, isFalse);
      expect(store.wasCleared, isFalse);

      // 存储恢复后同进程重试（前台恢复入口），无需杀进程。
      await provider.retryPendingStorageRecovery();

      expect(store.readAttempts, 3);
      expect(provider.authState, AuthState.authenticated);
      expect(provider.isLoggedIn, isTrue);
      expect(provider.hasPendingStorageRecovery, isFalse);
    });

    test('重试仍临时失败时保持恢复未决，可再次重试', () async {
      final adapter = _MockDioAdapter();
      final store = _FlakySessionStore(
        StoredAuthCredentials(
          token: 'valid-access-token',
          refreshToken: 'valid-refresh-token',
          accessTokenExpiresAt: DateTime.now().add(const Duration(hours: 1)),
          refreshTokenExpiresAt: DateTime.now().add(const Duration(days: 20)),
          userJson: jsonEncode(_userJson),
        ),
        failReadCount: 5,
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
      expect(provider.hasPendingStorageRecovery, isTrue);

      // 存储仍未恢复：重试失败但保持未决状态，可等待下次前台恢复再试。
      await provider.retryPendingStorageRecovery();

      expect(provider.authState, AuthState.recoveryFailed);
      expect(provider.hasPendingStorageRecovery, isTrue);
      expect(store.wasCleared, isFalse);
      expect(store.stored.token, 'valid-access-token');
    });

    test('BAD_DECRYPT 永久损坏不进入恢复未决状态', () async {
      final adapter = _MockDioAdapter();
      final store = _FlakySessionStore(
        StoredAuthCredentials(
          token: 'corrupted-access-token',
          refreshToken: 'corrupted-refresh-token',
          accessTokenExpiresAt: DateTime.now().add(const Duration(hours: 1)),
          refreshTokenExpiresAt: DateTime.now().add(const Duration(days: 20)),
          userJson: jsonEncode(_userJson),
        ),
      )
        ..readException = badDecryptPlatformException()
        ..failReadCount = 5;
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
        ..httpClientAdapter = adapter;

      final provider = AuthProvider(
        dio,
        credentialStore: store,
        loadStoredAuth: false,
        onAuthenticated: () {},
      );

      await provider.initializeStoredAuth();

      // 永久损坏已清理并进入 guest，可重新登录；不挂起在恢复等待界面。
      expect(provider.authState, AuthState.guest);
      expect(provider.hasPendingStorageRecovery, isFalse);
      expect(store.wasCleared, isTrue);
    });
  });
}
