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
