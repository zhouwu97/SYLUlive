/// 供各类教务缓存使用的最小策略接口，避免存储层反向依赖策略实现。
abstract interface class AcademicPersistenceGate {
  bool get allowPersonalDataPersistence;
  bool get allowPersonalDataRead;
}

/// Provider 没有直接持有 Policy 实例时使用的轻量账号门。
final class RegistryAcademicPersistenceGate implements AcademicPersistenceGate {
  const RegistryAcademicPersistenceGate(this.appUserId);

  final String appUserId;

  @override
  bool get allowPersonalDataPersistence =>
      AcademicPersistenceRegistry.allowsWrite(appUserId);

  @override
  bool get allowPersonalDataRead =>
      AcademicPersistenceRegistry.allowsRead(appUserId);
}

/// 供不在 Provider 注入图中的缓存（如 AI Gateway）读取当前账号策略。
final class AcademicPersistenceRegistry {
  static final Map<String, bool> _enabled = <String, bool>{};
  static final Map<String, bool> _readable = <String, bool>{};
  static final Map<String, Future<void>> _readiness = <String, Future<void>>{};

  static bool allowsWrite(String appUserId) =>
      _enabled[appUserId.trim()] ?? false;

  static bool allowsRead(String appUserId) =>
      _readable[appUserId.trim()] ?? false;

  static void set(String appUserId, {required bool enabled}) {
    final key = appUserId.trim();
    if (key.isEmpty) return;
    _enabled[key] = enabled;
    _readable[key] = enabled;
  }

  static void setReadiness(String appUserId, Future<void> readiness) {
    final key = appUserId.trim();
    if (key.isNotEmpty) _readiness[key] = readiness;
  }

  static Future<void> waitUntilReady(String appUserId) async {
    await _readiness[appUserId.trim()];
  }

  static void clear(String appUserId) {
    final key = appUserId.trim();
    _enabled.remove(key);
    _readable.remove(key);
    _readiness.remove(key);
  }
}
