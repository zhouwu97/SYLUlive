import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/providers/auth_provider.dart';

class _RefreshAdapter implements HttpClientAdapter {
  int fetchCount = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    fetchCount++;
    await requestStream?.drain<void>();
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

class _SessionStore implements SessionAuthCredentialStore {
  StoredAuthCredentials stored;

  _SessionStore(this.stored);

  @override
  Future<StoredAuthCredentials> read() async => stored;

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
    stored = const StoredAuthCredentials();
  }
}

const _userJson = <String, dynamic>{
  'id': 1,
  'student_id': '20260001',
  'nickname': '用户1',
  'created_at': '2026-07-13T10:00:00Z',
  'legal_consents_active': true,
  'legal_consents_required': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('并发刷新共用一个请求并原子更新刷新凭据', () async {
    final adapter = _RefreshAdapter();
    final store = _SessionStore(StoredAuthCredentials(
      token: 'access-before-refresh',
      refreshToken: 'refresh-before-refresh',
      accessTokenExpiresAt: DateTime.now().add(const Duration(hours: 1)),
      refreshTokenExpiresAt: DateTime.now().add(const Duration(days: 30)),
      userJson: jsonEncode(_userJson),
    ));
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
      ..httpClientAdapter = adapter;
    final provider = AuthProvider(
      dio,
      credentialStore: store,
      loadStoredAuth: false,
      onAuthenticated: () {},
    );

    await provider.initializeStoredAuth();
    final results = await Future.wait([
      provider.refreshSession(),
      provider.refreshSession(),
    ]);

    expect(results, [true, true]);
    expect(adapter.fetchCount, 1);
    expect(provider.token, 'access-after-refresh');
    expect(store.stored.refreshToken, 'refresh-after-refresh');
  });
}
