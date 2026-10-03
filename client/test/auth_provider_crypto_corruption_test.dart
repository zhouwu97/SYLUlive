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

/// 9.2.4 在 Android 上把 Java 堆栈放进 PlatformException.details，
/// code 固定为 "Exception encountered"，message 只是方法名。
PlatformException badDecryptPlatformException() => PlatformException(
      code: 'Exception encountered',
      message: 'read',
      details: 'javax.crypto.BadPaddingException: error:1e000065:Cipher '
          'functions:OPENSSL_internal:BAD_DECRYPT\n'
          '\tat com.it_nomads.fluttersecurestorage.ciphers.'
          'StorageCipher18Implementation.decrypt(StorageCipher18Implementation.java:57)',
    );

PlatformException keystoreBusyException() => PlatformException(
      code: 'Exception encountered',
      message: 'read',
      details: 'java.security.KeyStoreException: Keystore busy',
    );

/// 使用真实平台凭据存储（AppSecretStore + AppPreferencesStore）构造 AuthProvider，
/// 覆盖 _PlatformAuthCredentialStore.read/writeSession/clear 的损坏恢复语义。
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final secureStore = <String, String>{};
  // 标记为“密文损坏”的键：读取时抛 BAD_DECRYPT；删除/写入不经过解密，照常成功。
  final corruptedKeys = <String>{};
  // 标记为“临时故障”的键：读取时抛 KeyStore busy。
  final transientFailingKeys = <String>{};
  late String tempRoot;

  setUpAll(() async {
    tempRoot = (await Directory.systemTemp.createTemp('auth_crypto_test_'))
        .path;
  });

  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
    secureStore.clear();
    corruptedKeys.clear();
    transientFailingKeys.clear();
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
          if (corruptedKeys.contains(key)) throw badDecryptPlatformException();
          if (transientFailingKeys.contains(key)) {
            throw keystoreBusyException();
          }
          return secureStore[key];
        case 'write':
          secureStore[key!] = args['value'] as String;
          corruptedKeys.remove(key);
          transientFailingKeys.remove(key);
          return null;
        case 'delete':
          secureStore.remove(key);
          corruptedKeys.remove(key);
          transientFailingKeys.remove(key);
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

  test('冷启动 BAD_DECRYPT 只清理认证命名空间，重新登录后冷启动恢复正常', () async {
    secureStore['auth_token'] = 'ciphertext-token';
    corruptedKeys.add('auth_token');
    secureStore['auth_refresh_token'] = 'ciphertext-refresh';
    corruptedKeys.add('auth_refresh_token');
    secureStore['ai_provider_key'] = 'sk-keep-me';
    secureStore['edu_pwd_20260001'] = 'ciphertext-edu';
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setString('auth_user', jsonEncode(_userJson(1)));

    final adapter = _QueuedAuthAdapter();
    final provider = _platformProvider(adapter, loadStoredAuth: true);
    await provider.initializeStoredAuth();

    // 认证命名空间全部清理，非认证内容必须保留。
    expect(provider.authState, AuthState.guest);
    expect(provider.isLoggedIn, isFalse);
    expect(secureStore.containsKey('auth_token'), isFalse);
    expect(secureStore.containsKey('auth_refresh_token'), isFalse);
    expect(prefs.getString('auth_user'), isNull);
    expect(secureStore['ai_provider_key'], 'sk-keep-me');
    expect(secureStore['edu_pwd_20260001'], 'ciphertext-edu');

    // 同一会话内直接重新登录成功，新会话写入安全存储。
    adapter.enqueue(200, {'token': 'token-new', 'user': _userJson(1)});
    final result = await provider.login('account', 'password');
    expect(result.success, isTrue, reason: result.errorMessage);
    expect(provider.authState, AuthState.authenticated);
    expect(provider.token, 'token-new');
    expect(secureStore['auth_token'], 'token-new');
    expect(jsonDecode(prefs.getString('auth_user')!)['id'], 1);

    // 重新登录后的会话在下次冷启动正常恢复，不再卡在 guest。
    final restarted =
        _platformProvider(_QueuedAuthAdapter(), loadStoredAuth: true);
    await restarted.initializeStoredAuth();
    expect(restarted.authState, AuthState.authenticated);
    expect(restarted.token, 'token-new');
  });

  test('密码错误时展示服务端错误，不触发本地凭据清理', () async {
    secureStore['auth_token'] = 'old-token';
    secureStore['auth_refresh_token'] = 'old-refresh';
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setString('auth_user', jsonEncode(_userJson(1)));

    final adapter = _QueuedAuthAdapter()
      ..enqueue(401, {'code': 'INVALID_PASSWORD', 'error': 'APP 密码错误'});
    final provider = _platformProvider(adapter, loadStoredAuth: true);
    await provider.initializeStoredAuth();
    expect(provider.authState, AuthState.authenticated);

    final result = await provider.login('account', 'wrong-password');
    expect(result.success, isFalse);
    expect(result.errorMessage, 'APP 密码错误');
    expect(result.statusCode, 401);
    // 服务端拒绝的登录不进入本地凭据写入路径，旧会话原样保留。
    expect(provider.authState, AuthState.authenticated);
    expect(provider.token, 'old-token');
    expect(secureStore['auth_token'], 'old-token');
    expect(prefs.getString('auth_user'), jsonEncode(_userJson(1)));
  });

  test('正确密码遇旧密文损坏仍能写入并建立新会话', () async {
    secureStore['auth_token'] = 'corrupted-cipher';
    corruptedKeys.add('auth_token');
    secureStore['auth_refresh_token'] = 'corrupted-cipher-refresh';
    corruptedKeys.add('auth_refresh_token');
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setString('auth_user', jsonEncode(_userJson(1)));

    final adapter = _QueuedAuthAdapter()
      ..enqueue(200, {'token': 'token-new', 'user': _userJson(1)});
    final provider = _platformProvider(adapter, loadStoredAuth: false);
    final result = await provider.login('account', 'password');

    // 服务器已验证的登录不被无法解密的旧密文阻塞。
    expect(result.success, isTrue, reason: result.errorMessage);
    expect(provider.authState, AuthState.authenticated);
    expect(provider.token, 'token-new');
    expect(secureStore['auth_token'], 'token-new');
    expect(secureStore.containsKey('auth_refresh_token'), isFalse);
    expect(jsonDecode(prefs.getString('auth_user')!)['id'], 1);
  });

  test('临时 KeyStore 故障时正确密码登录失败（失败关闭），不误删本地凭据', () async {
    secureStore['auth_token'] = 'old-cipher';
    transientFailingKeys.add('auth_token');
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setString('auth_user', jsonEncode(_userJson(1)));

    final adapter = _QueuedAuthAdapter()
      ..enqueue(200, {'token': 'token-new', 'user': _userJson(1)});
    final provider = _platformProvider(adapter, loadStoredAuth: false);
    final result = await provider.login('account', 'password');

    expect(result.success, isFalse);
    // 临时故障不清理、不覆盖：旧密文与用户快照原样保留，稍后重试。
    expect(secureStore['auth_token'], 'old-cipher');
    expect(prefs.getString('auth_user'), jsonEncode(_userJson(1)));
    expect(provider.authState, isNot(AuthState.authenticated));
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
