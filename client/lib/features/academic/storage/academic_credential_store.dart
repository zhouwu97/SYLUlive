import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../platform/contracts/secure_store.dart';
import '../domain/academic_provider.dart';

/// 本机教务账号的可持久化凭据。
///
/// Cookie 和 Session 由独立加密 Artifact 管理，不混入密码的保留周期。
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

/// 新统一架构的身份隔离接口。与旧 App 用户接口并存，避免破坏旧实现。
abstract interface class IdentityScopedAcademicCredentialStore {
  Future<AcademicCredential?> readForIdentity(AcademicIdentityKey identity);

  Future<void> writeForIdentity(
    AcademicIdentityKey identity,
    AcademicCredential credential,
  );

  Future<void> deleteForIdentity(AcademicIdentityKey identity);
}

/// Android/iOS 使用系统安全存储，OHOS 由 [AppSecretStore.current] 选择
/// Asset Store，Web 使用 no-op 实现。
final class PlatformAcademicCredentialStore
    implements AcademicCredentialStore, IdentityScopedAcademicCredentialStore {
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
      throw StateError('本机安全存储暂不可用');
    }
    if (raw == null) return null;
    if (raw.isEmpty) throw StateError('本机教务凭据无法读取');

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
      // 已有材料解析失败属于存储异常，不能误报缺少密码或隐式擦除。
      throw StateError('本机教务凭据无法读取');
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

  @override
  Future<AcademicCredential?> readForIdentity(
      AcademicIdentityKey identity) async {
    final credential = await _readByKey(_identityKeyFor(identity));
    if (credential != null && credential.studentId != identity.studentId) {
      throw StateError('本机教务凭据与账号不匹配');
    }
    return credential;
  }

  @override
  Future<void> writeForIdentity(
    AcademicIdentityKey identity,
    AcademicCredential credential,
  ) =>
      _writeByKey(_identityKeyFor(identity), credential);

  @override
  Future<void> deleteForIdentity(AcademicIdentityKey identity) =>
      _secretStore.delete(_identityKeyFor(identity));

  /// 旧版本只有本科账号级凭据；仅匹配已确认本科身份时才清理迁移残留。
  Future<void> deleteLegacyForIdentity(AcademicIdentityKey identity) async {
    if (identity.providerId != AcademicProviderId.syluUndergraduate) return;
    final legacy = await read(identity.appUserId);
    if (legacy?.studentId.trim() == identity.studentId.trim()) {
      await delete(identity.appUserId);
    }
  }

  Future<AcademicCredential?> _readByKey(String key) async {
    String? raw;
    try {
      raw = await _secretStore.read(key);
    } catch (_) {
      throw StateError('本机安全存储暂不可用');
    }
    if (raw == null) return null;
    if (raw.isEmpty) throw StateError('本机教务凭据无法读取');
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('凭据格式错误');
      final data = Map<String, dynamic>.from(decoded);
      final studentId = data['student_id'];
      final password = data['password'];
      if (studentId is! String || password is! String) {
        throw const FormatException('凭据字段错误');
      }
      final credential =
          AcademicCredential(studentId: studentId.trim(), password: password);
      if (!credential.isValid) throw const FormatException('凭据为空');
      return credential;
    } catch (_) {
      // 保留原文供恢复；调用方展示存储异常，不能进入缺少密码的流程。
      throw StateError('本机教务凭据无法读取');
    }
  }

  Future<void> _writeByKey(String key, AcademicCredential credential) async {
    if (!credential.isValid) throw const FormatException('教务凭据无效');
    await _secretStore.write(
      key,
      jsonEncode(<String, String>{
        'student_id': credential.studentId.trim(),
        'password': credential.password,
      }),
    );
  }

  static String? _keyFor(String appUserId) {
    final normalized = appUserId.trim();
    if (normalized.isEmpty) return null;
    final hash = sha256.convert(utf8.encode(normalized)).toString();
    return 'academic_credential_v1_$hash';
  }

  static String _identityKeyFor(AcademicIdentityKey identity) =>
      'academic_credential_v2_${identity.storageId}';
}
