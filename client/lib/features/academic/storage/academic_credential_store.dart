import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../platform/contracts/secure_store.dart';

/// 本机教务账号的可持久化凭据。
///
/// Cookie、Session、验证码和请求参数不属于凭据模型，始终只留在内存中。
final class AcademicCredential {
  const AcademicCredential({
    required this.studentId,
    required this.password,
  });

  final String studentId;
  final String password;

  bool get isValid => studentId.trim().isNotEmpty && password.isNotEmpty;
}

/// 教务凭据存储抽象，按 App 用户隔离命名空间。
abstract interface class AcademicCredentialStore {
  Future<AcademicCredential?> read(String appUserId);

  Future<void> write(String appUserId, AcademicCredential credential);

  Future<void> delete(String appUserId);
}

/// Android/iOS 使用系统安全存储，OHOS 由 [AppSecretStore.current] 选择
/// Asset Store，Web 使用 no-op 实现。
final class PlatformAcademicCredentialStore implements AcademicCredentialStore {
  PlatformAcademicCredentialStore({AppSecretStore? secretStore})
      : _secretStore = secretStore ?? AppSecretStore.current();

  final AppSecretStore _secretStore;

  @override
  Future<AcademicCredential?> read(String appUserId) async {
    final key = _keyFor(appUserId);
    if (key == null) return null;
    String? raw;
    try {
      raw = await _secretStore.read(key);
    } catch (_) {
      // 安全存储暂时不可用不应阻断教务登录；调用方会按“无已保存凭据”处理。
      return null;
    }
    if (raw == null || raw.isEmpty) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('凭据格式错误');
      final data = Map<String, dynamic>.from(decoded);
      final studentId = data['student_id'];
      final password = data['password'];
      if (studentId is! String || password is! String) {
        throw const FormatException('凭据字段错误');
      }
      final credential = AcademicCredential(
        studentId: studentId.trim(),
        password: password,
      );
      if (!credential.isValid) throw const FormatException('凭据为空');
      return credential;
    } catch (_) {
      // 损坏凭据不可继续使用；删除失败也不能把底层异常带入 UI。
      try {
        await _secretStore.delete(key);
      } catch (_) {}
      return null;
    }
  }

  @override
  Future<void> write(String appUserId, AcademicCredential credential) async {
    final key = _keyFor(appUserId);
    if (key == null) return;
    if (!credential.isValid) throw const FormatException('教务凭据无效');
    final payload = jsonEncode(<String, String>{
      'student_id': credential.studentId.trim(),
      'password': credential.password,
    });
    await _secretStore.write(key, payload);
  }

  @override
  Future<void> delete(String appUserId) async {
    final key = _keyFor(appUserId);
    if (key == null) return;
    await _secretStore.delete(key);
  }

  static String? _keyFor(String appUserId) {
    final normalized = appUserId.trim();
    if (normalized.isEmpty) return null;
    final hash = sha256.convert(utf8.encode(normalized)).toString();
    return 'academic_credential_v1_$hash';
  }
}
