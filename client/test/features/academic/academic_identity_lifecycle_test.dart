import 'package:flutter_test/flutter_test.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart' hide AcademicCapabilities;
import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/application/academic_identity_lifecycle_coordinator.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/academic/domain/academic_repository.dart';
import 'package:shenliyuan/features/academic/storage/academic_connection_store.dart';
import 'package:shenliyuan/features/academic/storage/academic_credential_store.dart';
import 'package:shenliyuan/features/academic/storage/academic_session_artifact_vault.dart';
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/platform/contracts/secure_store.dart';
import '../../helpers/personal_snapshot_test_fakes.dart';

const a = AcademicIdentityKey(
    appUserId: 'u',
    providerId: AcademicProviderId.syluUndergraduate,
    studentId: 'a');
const b = AcademicIdentityKey(
    appUserId: 'u',
    providerId: AcademicProviderId.syluGraduate,
    studentId: 'b');

class Secrets implements AppSecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class Repository implements AcademicRepository {
  int schoolCalls = 0;
  SessionState state = SessionState.unauthenticated;
  @override
  SessionState get sessionState => state;
  @override
  String? get studentId => 'a';
  @override
  AcademicSourceKind get sourceKind => AcademicSourceKind.local;
  @override
  Future<void> resetSession() async {
    state = SessionState.unauthenticated;
  }

  @override
  Future<void> restoreSession() async {
    schoolCalls++;
  }

  @override
  Future<LoginResult> login(
      {required String studentId, required String password}) async {
    schoolCalls++;
    return const LoginPageChanged(message: 'fixture');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  test('未初始化连接不授予联网许可，清理期间不能重新连接', () async {
    final prefs = await AppPreferencesStore.getInstance();
    final store = AcademicConnectionStore(a, prefs);
    expect(store.initialized, false);
    expect(store.connected, false);
    await store.setConnected(true);
    expect(store.connected, true);
    await store.setCleanupPending(true);
    expect(store.connected, false);
  });

  test('断开跨冷启动阻断密码登录、验证码和读取，显式重连恢复许可', () async {
    final secrets = Secrets();
    final files = MemoryAcademicSessionArtifactFileBackend();
    AcademicSessionArtifactVault session(AcademicIdentityKey id) =>
        AcademicSessionArtifactVault(
            identity: id, secretStore: secrets, fileBackend: files);
    final repo = Repository();
    final controller = AcademicSessionController(
        repository: repo, identity: a, sessionArtifactVaultFactory: session);
    await controller.syncAppUser('u');
    await controller.disconnect();
    await controller.login(studentId: 'a', password: 'p');
    await controller.refreshCaptcha();
    await controller.ensureAuthenticated();
    await controller.loadProfile();
    expect(repo.schoolCalls, 0);
    final restarted = AcademicSessionController(
        repository: repo, identity: a, sessionArtifactVaultFactory: session);
    await restarted.syncAppUser('u');
    await restarted.login(studentId: 'a', password: 'p');
    expect(repo.schoolCalls, 0);
    expect(restarted.academicState, AcademicState.disconnected);
    await restarted.reconnect();
    await restarted.login(studentId: 'a', password: 'p');
    expect(repo.schoolCalls, 1);
    controller.dispose();
    restarted.dispose();
  });

  test('完整清除幂等且删除身份密钥，其他身份与二课体测仍可读', () async {
    final secrets = Secrets();
    final files = MemoryAcademicSessionArtifactFileBackend();
    final secure = MemoryPersonalSnapshotSecureStore();
    final snapshots = MemoryPersonalSnapshotFileBackend();
    AesGcmAccountScopedSnapshotStore vault(AcademicIdentityKey? id) =>
        AesGcmAccountScopedSnapshotStore(
            appUserId: 'u',
            identityNamespace: id?.storageId,
            secureStore: secure,
            fileBackend: snapshots);
    AcademicSessionArtifactVault session(AcademicIdentityKey id) =>
        AcademicSessionArtifactVault(
            identity: id, secretStore: secrets, fileBackend: files);
    final credentials = PlatformAcademicCredentialStore(secretStore: secrets);
    for (final id in [a, b]) {
      await credentials.writeForIdentity(
          id, AcademicCredential(studentId: id.studentId, password: 'p'));
      await session(id).write(ProviderSessionArtifact(
          providerId: id.providerId,
          studentId: id.studentId,
          artifactVersion: 1,
          createdAt: DateTime.now(),
          validatedAt: null,
          opaqueProviderState: const {
            'cookies': ['fixture']
          }));
      for (final type in [
        PersonalDataType.academic,
        PersonalDataType.schedule
      ]) {
        await vault(id).write(
            type: type,
            schemaVersion: 1,
            sourceSystem: 'edu',
            sourceAccountId: id.studentId,
            payload: const {'value': 1});
      }
    }
    for (final type in [PersonalDataType.erke, PersonalDataType.physical]) {
      await vault(null).write(
          type: type,
          schemaVersion: 1,
          sourceSystem: 'other',
          sourceAccountId: 'a',
          payload: const {'value': 2});
    }
    await vault(null).write(
        type: PersonalDataType.academic,
        schemaVersion: 1,
        sourceSystem: 'edu',
        sourceAccountId: a.studentId,
        payload: const {'legacy': true});
    await vault(null).write(
        type: PersonalDataType.schedule,
        schemaVersion: 1,
        sourceSystem: 'edu',
        sourceAccountId: b.studentId,
        payload: const {'legacy': true});
    final controller = AcademicSessionController(
        repository: Repository(),
        identity: a,
        sessionArtifactVaultFactory: session);
    await controller.syncAppUser('u');
    final prefs = await AppPreferencesStore.getInstance();
    final lifecycle = AcademicIdentityLifecycleCoordinator(
        controller: controller,
        preferences: prefs,
        credentials: credentials,
        clearSession: (id) => session(id).delete(),
        clearLegacyVault: (id) async {
          for (final type in [
            PersonalDataType.academic,
            PersonalDataType.schedule
          ]) {
            await vault(null).deleteMatchingSource(
                type: type, sourceSystem: "edu", sourceAccountId: id.studentId);
          }
        },
        clearVault: (id) => vault(id).clearUser(),
        clearAuxiliary: () async {});
    await lifecycle.clearLocalIdentity(a);
    await lifecycle.clearLocalIdentity(a);
    await vault(null).write(type: PersonalDataType.academic, schemaVersion: 1,
        sourceSystem: 'edu', sourceAccountId: a.studentId,
        payload: const {'late': true});
    expect(await credentials.readForIdentity(a), isNull);
    expect(await session(a).read(), isNull);
    expect(secrets.values.keys.any((key) => key.contains(a.storageId)), false);
    expect(secure.values.keys.any((key) => key.contains(a.storageId)), false);
    expect(await credentials.readForIdentity(b), isNotNull);
    expect(await session(b).read(), isNotNull);
    for (final type in [PersonalDataType.academic, PersonalDataType.schedule]) {
      expect(
          await vault(a)
              .read(type: type, sourceSystem: 'edu', sourceAccountId: 'a'),
          isNull);
      expect(
          await vault(b)
              .read(type: type, sourceSystem: 'edu', sourceAccountId: 'b'),
          isNotNull);
    }
    for (final type in [PersonalDataType.erke, PersonalDataType.physical]) {
      expect(
          await vault(null)
              .read(type: type, sourceSystem: 'other', sourceAccountId: 'a'),
          isNotNull);
    }
    expect(
        await vault(null).read(
            type: PersonalDataType.academic,
            sourceSystem: 'edu',
            sourceAccountId: a.studentId),
        isNull);
    expect(
        await vault(null).read(
            type: PersonalDataType.schedule,
            sourceSystem: 'edu',
            sourceAccountId: b.studentId),
        isNotNull);
    expect(controller.identity, a);
    expect(AcademicConnectionStore(a, prefs).cleanupPending, false);
    controller.dispose();
  });

  test('清理失败保持 pending 和断开，重试后仅移除 pending', () async {
    final secrets = Secrets();
    final session = AcademicSessionArtifactVault(
        identity: a,
        secretStore: secrets,
        fileBackend: MemoryAcademicSessionArtifactFileBackend());
    final controller = AcademicSessionController(
        repository: Repository(),
        identity: a,
        sessionArtifactVaultFactory: (_) => session);
    await controller.syncAppUser('u');
    final prefs = await AppPreferencesStore.getInstance();
    var fail = true;
    final lifecycle = AcademicIdentityLifecycleCoordinator(
        controller: controller,
        preferences: prefs,
        credentials: PlatformAcademicCredentialStore(secretStore: secrets),
        clearSession: (_) => session.delete(),
        clearLegacyVault: (_) async {},
        clearVault: (_) async {
          if (fail) throw StateError('fixture');
        },
        clearAuxiliary: () async {});
    await expectLater(lifecycle.clearLocalIdentity(a), throwsStateError);
    expect(AcademicConnectionStore(a, prefs).cleanupPending, true);
    await expectLater(controller.reconnect(), throwsStateError);
    expect(await controller.remoteAccessAllowed(), false);
    fail = false;
    await lifecycle.retryPending(a);
    expect(AcademicConnectionStore(a, prefs).cleanupPending, false);
    expect(AcademicConnectionStore(a, prefs).connected, false);
    controller.dispose();
  });
}
