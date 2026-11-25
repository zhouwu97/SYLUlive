import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:shenliyuan/features/physical/physical_data_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/physical_credential_store.dart';
import 'package:shenliyuan/platform/contracts/secure_store.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

class _MemorySecureStore implements AppSecretStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('保存后的特殊字符密码仅作一次 MD5，兼容嵌套登录响应', () async {
    AppPreferencesStore.setMockInitialValues({});
    final store = PhysicalCredentialStore(secureStore: _MemorySecureStore());
    const password = ' @Fixture0+&=%中文• ';
    await store.write('fixture', password);
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      expect(options.data['password'],
          md5.convert(utf8.encode(password)).toString());
      expect(options.data['password'],
          isNot(md5.convert(utf8.encode(password.trim())).toString()));
      handler.resolve(Response(requestOptions: options, statusCode: 200, data: {
        'status': 'PASS',
        'data': {
          'user_id': 'fixture-user',
          'token': 'fixture-token',
          'school_date': '2026'
        }
      }));
    }));
    final login = await PhysicalDataSyncService(dio: dio)
        .login('fixture', (await store.read('fixture'))!);
    expect(login.userId, 'fixture-user');
    expect(login.token, 'fixture-token');
  });

  for (final (body, code) in <(Object, String)>[
    ({'status': 'FAIL', 'message': '用户名或者密码错误'}, 'physical_credential_invalid'),
    ({'status': 'FAIL', 'message': '服务器繁忙'}, 'physical_refresh_failed'),
    ({'status': 'PASS', 'message': 'noCode'}, 'physical_refresh_failed'),
    ('<html>service unavailable</html>', 'physical_refresh_failed'),
    (
      {'status': 'FAIL', 'user_id': 'stale', 'token': 'stale'},
      'physical_refresh_failed'
    ),
  ]) {
    test('体测只把明确密码拒绝分类为凭据失效：$body', () async {
      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: body));
      }));
      final result = await PhysicalDataSyncService(dio: dio).syncLatest(
          appUserId: 'fixture',
          sourceAccountId: 'fixture',
          password: 'fixture');
      expect(result.errorCode, code);
    });
  }

  test('读取时将旧版体测明文密码迁移到安全存储', () async {
    AppPreferencesStore.setMockInitialValues(<String, Object>{
      'sylu_physical_test_pwd_20260001': 'legacy-password',
    });
    final secure = _MemorySecureStore();
    final store = PhysicalCredentialStore(secureStore: secure);

    expect(await store.read('20260001'), 'legacy-password');
    expect(
      secure.values['secure_physical_test_pwd_20260001'],
      'legacy-password',
    );
    final preferences = await AppPreferencesStore.getInstance();
    expect(preferences.containsKey('sylu_physical_test_pwd_20260001'), isFalse);
  });

  test('保存与删除均清理旧版明文键', () async {
    AppPreferencesStore.setMockInitialValues(<String, Object>{
      'sylu_physical_test_pwd_20260001': 'old-password',
    });
    final secure = _MemorySecureStore();
    final store = PhysicalCredentialStore(secureStore: secure);

    await store.write('20260001', 'new-password');
    expect(await store.read('20260001'), 'new-password');
    await store.delete('20260001');
    expect(await store.read('20260001'), isNull);
  });
}
