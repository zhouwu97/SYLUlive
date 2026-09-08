import '../../../platform/contracts/preferences_store.dart';
import '../../campus_data/storage/account_scoped_snapshot_store.dart';
import '../../campus_data/storage/academic_cache_store.dart';
import '../../campus_data/storage/schedule_cache_store.dart';
import '../domain/academic_provider.dart';
import '../storage/academic_connection_store.dart';
import '../storage/academic_credential_store.dart';
import '../storage/academic_persistence_policy.dart';
import '../storage/academic_persistence_gate.dart';
import '../storage/academic_session_artifact_vault.dart';
import '../storage/academic_storage_preferences.dart';
import 'academic_session_controller.dart';

/// 身份清理的唯一事务入口。保留失败日志，物理删除可安全重试。
final class AcademicIdentityLifecycleCoordinator {
  AcademicIdentityLifecycleCoordinator({
    required this.controller,
    required this.preferences,
    IdentityScopedAcademicCredentialStore? credentials,
    this.clearVault,
    this.clearSession,
    this.clearAuxiliary,
  }) : credentials = credentials ?? PlatformAcademicCredentialStore();

  final AcademicSessionController controller;
  final AppPreferencesStore preferences;
  final IdentityScopedAcademicCredentialStore credentials;
  final Future<void> Function(AcademicIdentityKey)? clearVault;
  final Future<void> Function(AcademicIdentityKey)? clearSession;
  final Future<void> Function()? clearAuxiliary;

  static final Map<AcademicIdentityKey, Future<void>> _inFlight = {};

  Future<void> clearLocalIdentity(AcademicIdentityKey identity) {
    final running = _inFlight[identity];
    if (running != null) return running;
    final operation = _clearLocalIdentity(identity);
    _inFlight[identity] = operation;
    return operation.whenComplete(() {
      if (identical(_inFlight[identity], operation)) _inFlight.remove(identity);
    });
  }

  Future<void> _clearLocalIdentity(AcademicIdentityKey identity) async {
    if (!identity.isValid) throw ArgumentError('教务身份不完整');
    final connection = AcademicConnectionStore(identity, preferences);
    Object? failure;
    // 一个删除失败不能阻止其他秘密被清理；最后统一保留 pending。
    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action();
      } catch (error) {
        failure ??= error;
      }
    }

    final isCurrent = controller.identity == identity;
    if (isCurrent) {
      AcademicPersistenceRegistry.set(identity.appUserId, enabled: false);
      await attempt(controller.disconnect);
    }
    await connection.setConnected(false);
    await connection.setCleanupPending(true);
    await attempt(() => clearSession != null
        ? clearSession!(identity)
        : AcademicSessionArtifactVault(identity: identity).delete());
    await attempt(() => credentials.deleteForIdentity(identity));
    final credentialStore = credentials;
    if (credentialStore is PlatformAcademicCredentialStore) {
      await attempt(() => credentialStore.deleteLegacyForIdentity(identity));
    }
    final settings = AcademicStoragePreferences(
      appUserId: identity.appUserId,
      identity: identity,
      store: preferences,
    );
    await attempt(settings.migrateLegacyPreferences);
    await attempt(() => settings.setSaveCredentials(false));
    await attempt(() async {
      if (clearVault != null) {
        await clearVault!(identity);
        return;
      }
      // 先排空各数据类型的写队列，再删除此身份专属 DEK。
      final vault = AesGcmAccountScopedSnapshotStore(
        appUserId: identity.appUserId,
        identityNamespace: identity.storageId,
      );
      await AcademicCacheStore(
        appUserId: identity.appUserId,
        sourceAccountId: identity.studentId,
        sourceSystem: identity.providerId.value,
        identityNamespace: identity.storageId,
        snapshotStore: vault,
      ).clearAll();
      await ScheduleCacheStore(
        appUserId: identity.appUserId,
        sourceAccountId: identity.studentId,
        sourceSystem: identity.providerId.value,
        identityNamespace: identity.storageId,
        snapshotStore: vault,
      ).clearAll();
      await vault.clearUser();
      await vault.close();
    });
    if (isCurrent) {
      await attempt(
          clearAuxiliary ?? AcademicPersistencePolicy.clearAuxiliaryData);
    }
    await attempt(settings.clear);
    await attempt(() => settings.setSaveAcademicData(false));
    if (failure != null) throw failure!;
    await connection.setCleanupPending(false);
  }

  Future<void> retryPending(AcademicIdentityKey identity) async {
    if (AcademicConnectionStore(identity, preferences).cleanupPending) {
      await clearLocalIdentity(identity);
    }
  }
}
