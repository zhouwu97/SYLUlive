import 'dart:async';

import '../app_platform.dart';

/// 安全凭据存储能力的服务接口。
///
/// 计划 11.2：鸿蒙端已有 ArkTS 版基于 Asset Store Kit 的实现
/// （`_OhosAuthCredentialStore` 见 `lib/providers/auth_provider.dart`）。
/// 本接口用于在未来阶段把该实现从 Provider 中外提、与 Android 的
/// `flutter_secure_storage` 实现统一为同一抽象。
///
/// 计划 3.4 / 7.2 一致性保障：
/// - 凭据不完整 → 清除残留并回到登录页，不允许半登录状态。
/// - 不允许降级到明文 SharedPreferences。
abstract class SecureStorageService {
  AppPlatform get platform;
  bool get isSupported;

  /// 读取 App 凭据。凭据不完整（仅 token 或仅 userJson）时返回 null。
  Future<StoredCredentials?> readCredentials();

  /// 写入 App 凭据。token 写入成功但 userJson 写入失败时实现必须自行回滚。
  Future<void> writeCredentials({
    required String token,
    required String userJson,
  });

  /// 清除 App 凭据，并保证 token / userJson 两份条目同步删除。
  Future<void> clearCredentials();

  /// 保存教务密码，按学号命名的私密条目。
  Future<void> writeEduPassword({
    required String studentId,
    required String password,
  });

  Future<String?> readEduPassword({required String studentId});

  Future<void> deleteEduPassword({required String studentId});

  Future<void> dispose();
}

/// App 凭据的轻量值对象。
class StoredCredentials {
  const StoredCredentials({required this.token, required this.userJson});

  final String token;
  final String userJson;
}

/// 未对接平台的占位实现。任何写入均不持久化，读取返回 null。
class NoopSecureStorageService implements SecureStorageService {
  const NoopSecureStorageService({required this.platform});

  @override
  final AppPlatform platform;

  @override
  bool get isSupported => false;

  @override
  Future<StoredCredentials?> readCredentials() async => null;

  @override
  Future<void> writeCredentials({
    required String token,
    required String userJson,
  }) async {}

  @override
  Future<void> clearCredentials() async {}

  @override
  Future<void> writeEduPassword({
    required String studentId,
    required String password,
  }) async {}

  @override
  Future<String?> readEduPassword({required String studentId}) async => null;

  @override
  Future<void> deleteEduPassword({required String studentId}) async {}

  @override
  Future<void> dispose() async {}
}