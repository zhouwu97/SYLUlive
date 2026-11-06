import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shenliyuan/features/ai_device_bridge/device_credential_store.dart';
import 'package:shenliyuan/platform/contracts/secure_store.dart';

void main() {
  test('安全存储临时失败不删除密码，下次读取可恢复', () async {
    final secure = _FaultStore();
    final store = DeviceCredentialStore(secretStore: secure);
    await store.writeErke('fixture',
        const DeviceErkeCredentials(casPassword: 'cas', erkePassword: 'erke'));
    secure.error = PlatformException(code: 'busy');
    await expectLater(store.readErke('fixture'), throwsStateError);
    expect(secure.deletes, 0);
    secure.error = null;
    expect((await store.readErke('fixture'))?.erkePassword, 'erke');
  });

  test('仅永久密文损坏清理坏键，格式异常保留原值', () async {
    final secure = _FaultStore();
    final store = DeviceCredentialStore(secretStore: secure);
    await store.writeErke('fixture',
        const DeviceErkeCredentials(casPassword: 'cas', erkePassword: 'erke'));
    secure.raw = 'invalid-json';
    await expectLater(store.readErke('fixture'), throwsStateError);
    expect(secure.deletes, 0);
    secure.error =
        PlatformException(code: 'decrypt', details: 'BadPaddingException');
    expect(await store.readErke('fixture'), isNull);
    expect(secure.deletes, 1);
  });
  test('二课凭据只写安全存储且按账号隔离', () async {
    final secure = MemorySecretStore();
    final store = DeviceCredentialStore(secretStore: secure);
    const credentials = DeviceErkeCredentials(
      casPassword: 'cas-secret',
      erkePassword: 'erke-secret',
    );

    await store.writeErke('20260001', credentials);

    final restored = await store.readErke('20260001');
    expect(restored?.casPassword, 'cas-secret');
    expect(restored?.erkePassword, 'erke-secret');
    expect(await store.readErke('20260002'), isNull);

    await store.deleteErke('20260001');
    expect(await store.readErke('20260001'), isNull);
  });
}

class _FaultStore implements AppSecretStore {
  String? raw;
  Object? error;
  int deletes = 0;
  @override
  Future<String?> read(String key) async {
    if (error != null) throw error!;
    return raw;
  }

  @override
  Future<void> write(String key, String value) async => raw = value;
  @override
  Future<void> delete(String key) async {
    deletes++;
    raw = null;
  }
}
