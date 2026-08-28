import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/ai_device_bridge/device_credential_store.dart';
import 'package:shenliyuan/platform/contracts/secure_store.dart';

void main() {
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
