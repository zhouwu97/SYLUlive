import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../platform/contracts/secure_store.dart';

class DeviceErkeCredentials {
  const DeviceErkeCredentials({
    required this.casPassword,
    required this.erkePassword,
  });

  final String casPassword;
  final String erkePassword;

  bool get isComplete =>
      casPassword.trim().isNotEmpty && erkePassword.trim().isNotEmpty;
}

/// 将设备自动刷新所需的二课凭据保存在系统安全存储中。
///
/// 存储键只包含学号指纹；凭据不会进入普通偏好、日志、设备任务参数或服务端。
class DeviceCredentialStore {
  DeviceCredentialStore({AppSecretStore? secretStore})
      : _secretStore = secretStore ?? AppSecretStore.current();

  final AppSecretStore _secretStore;

  String _erkeKey(String sourceAccountId) {
    final digest = sha256.convert(utf8.encode(sourceAccountId.trim()));
    return 'secure_ai_erke_credentials_v1_$digest';
  }

  Future<DeviceErkeCredentials?> readErke(String sourceAccountId) async {
    if (sourceAccountId.trim().isEmpty) return null;
    String? raw;
    try {
      raw = await _secretStore.read(_erkeKey(sourceAccountId));
    } catch (error) {
      if (classifySecretStoreFailure(error) ==
          SecretStoreFailureKind.corruptedCiphertext) {
        await deleteErke(sourceAccountId);
        return null;
      }
      throw StateError('本机安全存储暂不可用');
    }
    if (raw == null || raw.isEmpty) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map) throw const FormatException('凭据格式错误');
      final credentials = DeviceErkeCredentials(
        casPassword: value['cas_password']?.toString() ?? '',
        erkePassword: value['erke_password']?.toString() ?? '',
      );
      if (!credentials.isComplete) throw const FormatException('凭据字段为空');
      return credentials;
    } catch (_) {
      // 格式异常可能可恢复；不能把存储故障当作密码缺失并隐式删除。
      throw StateError('本机二课凭据无法读取');
    }
  }

  Future<void> writeErke(
    String sourceAccountId,
    DeviceErkeCredentials credentials,
  ) {
    if (sourceAccountId.trim().isEmpty || !credentials.isComplete) {
      throw ArgumentError('二课凭据或账号无效');
    }
    return _secretStore.write(
      _erkeKey(sourceAccountId),
      jsonEncode(<String, String>{
        'cas_password': credentials.casPassword,
        'erke_password': credentials.erkePassword,
      }),
    );
  }

  Future<void> deleteErke(String sourceAccountId) async {
    if (sourceAccountId.trim().isEmpty) return;
    await _secretStore.delete(_erkeKey(sourceAccountId));
  }
}
