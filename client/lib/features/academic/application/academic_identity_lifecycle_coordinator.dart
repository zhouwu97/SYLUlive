import '../../../platform/contracts/preferences_store.dart';
import '../../../services/home_widget_service.dart';
import '../../../services/course_reminder_service.dart';
import '../../campus_data/storage/account_scoped_snapshot_store.dart';
import '../../campus_data/storage/academic_cache_store.dart';
import '../../campus_data/storage/schedule_cache_store.dart';
import '../../campus_data/storage/personal_snapshot_models.dart';
import '../domain/academic_provider.dart';
import '../storage/academic_connection_store.dart';
import '../storage/academic_credential_store.dart';
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
    this.clearLegacyVault,
    this.clearSession,
    this.clearAuxiliary,
    this.includeLegacyAuxiliary = false,
  }) : credentials = credentials ?? PlatformAcademicCredentialStore();

  final AcademicSessionController controller;
  final AppPreferencesStore preferences;
  final IdentityScopedAcademicCredentialStore credentials;
  final Future<void> Function(AcademicIdentityKey)? clearVault;
  final Future<void> Function(AcademicIdentityKey)? clearLegacyVault;
  final Future<void> Function(AcademicIdentityKey)? clearSession;
  final Future<void> Function()? clearAuxiliary;
  final bool includeLegacyAuxiliary;

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
    await attempt(() async {
      if (clearLegacyVault != null) {
        await clearLegacyVault!(identity);
        return;
      }
      // 旧 edu 来源只属于本科兼容存储；研究生不能据此认领同学号的数据。
      if (identity.providerId != AcademicProviderId.syluUndergraduate) return;
      final legacy =
          AesGcmAccountScopedSnapshotStore(appUserId: identity.appUserId);
      try {
        for (final type in [
          PersonalDataType.academic,
          PersonalDataType.schedule
        ]) {
          await legacy.deleteMatchingSource(
              type: type,
              sourceSystem: 'edu',
              sourceAccountId: identity.studentId);
        }
      } finally {
        await legacy.close();
      }
    });
    if (clearAuxiliary != null) {
      await attempt(clearAuxiliary!);
    } else {
      await attempt(() => HomeWidgetService.clearCourseDataForIdentity(identity,
          includeLegacy: isCurrent || includeLegacyAuxiliary));
      await attempt(() => CourseReminderService.instance.clearForIdentity(
          identity,
          includeLegacy: isCurrent || includeLegacyAuxiliary));
    }
    await attempt(settings.clear);
    await attempt(() => settings.setSaveAcademicData(false));
    await attempt(() async {
      final user = identity.appUserId;
      if (identity.providerId != AcademicProviderId.syluUndergraduate ||
          preferences.getString('edu_student_id_$user') != identity.studentId) {
        return;
      }
      // 旧账号级投影没有 provider 字段，只清除能由旧本科学号证明归属的记录。
      // 学号最后删除，前面任何失败都保留重试时的归属凭证。
      for (final prefix in [
        'edu_bound',
        'edu_authorized',
        'edu_session_state',
        'edu_grade',
        'edu_college',
        'edu_major',
        'edu_last_semester',
        'edu_student_id'
      ]) {
        if (!await preferences.remove('${prefix}_$user')) {
          throw StateError('清理旧教务身份偏好失败');
        }
      }
    });
    if (failure != null) throw failure!;
    await connection.setCleanupPending(false);
  }

  Future<void> retryPending(AcademicIdentityKey identity) async {
    if (AcademicConnectionStore(identity, preferences).cleanupPending) {
      await clearLocalIdentity(identity);
    }
  }
}
