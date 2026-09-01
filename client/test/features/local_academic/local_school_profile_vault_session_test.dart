import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/academic_cache_store.dart';
import 'package:shenliyuan/features/local_academic/local_school_profile.dart';
import 'package:shenliyuan/features/local_academic/local_school_session.dart';
import 'package:shenliyuan/features/local_academic/local_school_vault.dart';
import 'package:shenliyuan/platform/contracts/secure_store.dart';

import '../../helpers/personal_snapshot_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocalSchoolProfile', () {
    test('同一学号每次创建随机 UUID v4，ID 不从学号派生', () {
      final first = LocalSchoolProfile(
        appUserId: 'app-user-a',
        studentId: '20260001',
      );
      final second = LocalSchoolProfile(
        appUserId: 'app-user-a',
        studentId: '20260001',
      );

      expect(first.id, matches(LocalSchoolProfile.uuidV4Pattern));
      expect(second.id, matches(LocalSchoolProfile.uuidV4Pattern));
      expect(first.id, isNot(second.id));
      expect(first.id, isNot(contains(first.studentId)));
      expect(first.toMetadataJson(), isNot(contains('password')));
      expect(first.toMetadataJson(), isNot(contains('cookie')));
    });

    test('显式 Profile ID 必须是 UUID v4 且不能复用学号', () {
      expect(
        () => LocalSchoolProfile(
          id: '20260001',
          appUserId: 'app-user-a',
          studentId: '20260001',
        ),
        throwsArgumentError,
      );
      expect(
        () => LocalSchoolProfile(
          id: '11111111-1111-4111-8111-111111111111',
          appUserId: 'app-user-a',
          studentId: '11111111-1111-4111-8111-111111111111',
        ),
        throwsArgumentError,
      );
    });
  });

  group('LocalSchoolCredentialVault', () {
    test('凭据按 Profile 隔离，密码默认仅驻留内存', () async {
      final secrets = MemorySecretStore();
      final profileA = _profile('00000000-0000-4000-8000-000000000001');
      final profileB = _profile('00000000-0000-4000-8000-000000000002');
      final vaultA = _vault(profileA, secrets, 'profile-a');
      final vaultB = _vault(profileB, secrets, 'profile-b');
      final longCookie = 'SESSION=${List<String>.filled(900, 'x').join()}';

      await vaultA.writeCredentials(
        studentId: profileA.studentId,
        password: 'SECRET_SCHOOL_PASSWORD',
        cookie: longCookie,
      );

      final storedA = await vaultA.read();
      expect(storedA?.studentId, profileA.studentId);
      expect(storedA?.cookie, longCookie);
      expect(storedA?.password, isNull);
      expect(vaultA.ephemeralPassword, 'SECRET_SCHOOL_PASSWORD');
      expect(await vaultB.read(), isNull);
      expect(vaultA.namespace, isNot(vaultB.namespace));

      await vaultA.close();
      expect(vaultA.ephemeralPassword, isNull);
    });

    test('只有显式记住密码才持久化，取消后删除旧密码', () async {
      final profile = _profile('00000000-0000-4000-8000-000000000003');
      final vault = _vault(profile, MemorySecretStore(), 'profile-c');

      await vault.writeCredentials(
        studentId: profile.studentId,
        password: 'remembered-password',
        cookie: 'session-a',
        rememberPassword: true,
      );
      expect((await vault.read())?.password, 'remembered-password');

      await vault.writeCredentials(
        studentId: profile.studentId,
        password: 'ephemeral-password',
        cookie: 'session-b',
        rememberPassword: false,
      );
      expect((await vault.read())?.password, isNull);
      expect(vault.ephemeralPassword, 'ephemeral-password');
    });

    test('较短新值会删除旧值多余分块', () async {
      final secrets = _InspectableSecretStore();
      final profile = _profile('00000000-0000-4000-8000-000000000008');
      final vault = _vault(profile, secrets, 'profile-f');
      final longCookie = List<String>.filled(1600, 'x').join();

      await vault.writeCredentials(
        studentId: profile.studentId,
        cookie: longCookie,
      );
      expect(
        secrets.values.keys
            .where((key) => key.startsWith('${vault.namespace}cookie.')),
        hasLength(3),
      );

      await vault.writeCredentials(
        studentId: profile.studentId,
        cookie: 'short-cookie',
      );
      expect((await vault.read())?.cookie, 'short-cookie');
      expect(
        secrets.values.keys
            .where((key) => key.startsWith('${vault.namespace}cookie.')),
        hasLength(1),
      );
    });

    test('manifest 损坏时 clear 仍按上限清除残留分块', () async {
      final secrets = _InspectableSecretStore();
      final profile = _profile('00000000-0000-4000-8000-000000000009');
      final vault = _vault(profile, secrets, 'profile-g');

      await vault.writeCredentials(
        studentId: profile.studentId,
        cookie: List<String>.filled(900, 'x').join(),
      );
      secrets.values['${vault.namespace}cookie'] = '{broken-manifest';

      await vault.clear();
      expect(
        secrets.values.keys.where((key) => key.startsWith(vault.namespace)),
        isEmpty,
      );
    });

    test('manifest 提交失败后读取 fail-closed，clear 清除半写入块', () async {
      final secrets = _InspectableSecretStore();
      final profile = _profile('00000000-0000-4000-8000-00000000000a');
      final vault = _vault(profile, secrets, 'profile-h');

      await vault.writeCredentials(
        studentId: profile.studentId,
        cookie: List<String>.filled(900, 'x').join(),
      );
      secrets.failNextWriteKey = '${vault.namespace}cookie';

      await expectLater(
        vault.writeCredentials(
          studentId: profile.studentId,
          cookie: 'partially-written-cookie',
        ),
        throwsA(isA<LocalSchoolVaultException>()),
      );
      await expectLater(
        vault.read(),
        throwsA(isA<LocalSchoolVaultException>()),
      );

      await vault.clear();
      expect(
        secrets.values.keys.where((key) => key.startsWith(vault.namespace)),
        isEmpty,
      );
    });

    test('多字段事务中途失败后不会读取混合凭据', () async {
      final secrets = _InspectableSecretStore();
      final profile = _profile('00000000-0000-4000-8000-00000000000b');
      final vault = _vault(profile, secrets, 'profile-i');

      await vault.writeCredentials(
        studentId: profile.studentId,
        cookie: 'old-cookie',
        sessionMetadata: const <String, dynamic>{'term': 'old'},
      );
      secrets.failNextWriteKey = '${vault.namespace}session_metadata';

      await expectLater(
        vault.writeCredentials(
          studentId: '20260002',
          cookie: 'new-cookie',
          sessionMetadata: const <String, dynamic>{'term': 'new'},
        ),
        throwsA(isA<LocalSchoolVaultException>()),
      );
      expect(
        secrets.values['${vault.namespace}transaction_in_progress'],
        isNotNull,
      );
      await expectLater(
        vault.read(),
        throwsA(isA<LocalSchoolVaultException>()),
      );

      await vault.clear();
      expect(
        secrets.values.keys.where((key) => key.startsWith(vault.namespace)),
        isEmpty,
      );
    });
  });

  group('LocalSchoolSessionManager', () {
    test('多个过期请求只共享一次重新登录', () async {
      final profile = _profile('00000000-0000-4000-8000-000000000004');
      final vault = _vault(profile, MemorySecretStore(), 'profile-d');
      final reloginResult = Completer<LocalSchoolCredentials>();
      var reloginCount = 0;
      final manager = LocalSchoolSessionManager(
        profile: profile,
        vault: vault,
        reloginAction: (_) {
          reloginCount++;
          return reloginResult.future;
        },
      );
      manager.markExpired();

      final first = manager.execute(() async => 'first');
      final second = manager.execute(() async => 'second');
      await Future<void>.delayed(Duration.zero);

      expect(reloginCount, 1);
      expect(manager.state, LocalSchoolSessionState.relogging);
      expect(manager.inFlightRelogin, isNotNull);

      reloginResult.complete(
        LocalSchoolCredentials(
          studentId: profile.studentId,
          cookie: 'renewed-session',
        ),
      );
      expect(await Future.wait(<Future<String>>[first, second]), <String>[
        'first',
        'second',
      ]);
      expect(reloginCount, 1);
      expect(manager.state, LocalSchoolSessionState.active);
      expect((await vault.read())?.cookie, 'renewed-session');
    });

    test('Idle 状态不会隐式触发重新登录', () async {
      final profile = _profile('00000000-0000-4000-8000-000000000005');
      var reloginCount = 0;
      final manager = LocalSchoolSessionManager(
        profile: profile,
        vault: _vault(profile, MemorySecretStore(), 'profile-e'),
        reloginAction: (_) async {
          reloginCount++;
          return LocalSchoolCredentials(studentId: profile.studentId);
        },
      );

      await expectLater(
        manager.execute(() async => 'unexpected'),
        throwsA(isA<LocalSchoolSessionExpiredException>()),
      );
      expect(reloginCount, 0);
    });

    test('退出会使正在进行的重新登录失效且不能回写凭据', () async {
      final secrets = _InspectableSecretStore();
      final profile = _profile('00000000-0000-4000-8000-00000000000c');
      final vault = _vault(profile, secrets, 'profile-j');
      await vault.writeCredentials(
        studentId: profile.studentId,
        cookie: 'old-session',
      );
      final reloginResult = Completer<LocalSchoolCredentials>();
      final manager = LocalSchoolSessionManager(
        profile: profile,
        vault: vault,
        reloginAction: (_) => reloginResult.future,
      );
      manager.markExpired();

      final pendingRelogin = manager.relogin();
      await Future<void>.delayed(Duration.zero);
      expect(manager.state, LocalSchoolSessionState.relogging);

      await manager.logout();
      reloginResult.complete(
        LocalSchoolCredentials(
          studentId: profile.studentId,
          cookie: 'should-not-be-written',
        ),
      );

      await expectLater(
        pendingRelogin,
        throwsA(isA<LocalSchoolSessionException>()),
      );
      expect(manager.state, LocalSchoolSessionState.loggedOut);
      expect(
        secrets.values.keys.where((key) => key.startsWith(vault.namespace)),
        isEmpty,
      );
      expect(
        secrets.values.values.join(' '),
        isNot(contains('should-not-be-written')),
      );
    });
  });

  test('学业密文缓存按 App 用户与 Profile UUID 双重分区', () async {
    final secureStore = MemoryPersonalSnapshotSecureStore();
    final files = MemoryPersonalSnapshotFileBackend();
    final random = IncrementingRandomBytes();
    final profileA = _profile('00000000-0000-4000-8000-000000000006');
    final profileB = _profile('00000000-0000-4000-8000-000000000007');

    AccountScopedSnapshotStore snapshotStore(LocalSchoolProfile profile) {
      return AesGcmAccountScopedSnapshotStore(
        appUserId: '${profile.appUserId}/${profile.id}',
        secureStore: secureStore,
        fileBackend: files,
        randomBytes: random.call,
      );
    }

    final snapshotA = snapshotStore(profileA);
    final snapshotB = snapshotStore(profileB);
    expect(snapshotA.accountFingerprint, isNot(snapshotB.accountFingerprint));

    final cacheA = AcademicCacheStore(
      appUserId: '${profileA.appUserId}/${profileA.id}',
      sourceAccountId: profileA.studentId,
      snapshotStore: snapshotA,
    );
    final cacheB = AcademicCacheStore(
      appUserId: '${profileB.appUserId}/${profileB.id}',
      sourceAccountId: profileB.studentId,
      snapshotStore: snapshotB,
    );
    await cacheA.writeGrades(
      year: '2026',
      semester: 1,
      grades: const <Map<String, dynamic>>[
        <String, dynamic>{'name': '数据结构', 'grade': '91'},
      ],
    );
    await cacheA.writeExams(
      year: '2026',
      semester: 1,
      exams: const <Map<String, dynamic>>[
        <String, dynamic>{'name': '数据结构', 'location': 'A101'},
      ],
    );
    await cacheA.writeExams(
      exams: const <Map<String, dynamic>>[
        <String, dynamic>{'name': '全量考试'},
      ],
    );

    expect(await cacheB.readSnapshot(), isNull);
    expect(
      (await cacheA.readExams(year: '2026', semester: 1))?.single['location'],
      'A101',
    );
    expect((await cacheA.readExams())?.single['name'], '全量考试');
    expect(
      await cacheA.readExams(year: '2026', semester: 2),
      isNull,
    );
  });
}

LocalSchoolProfile _profile(String id) {
  return LocalSchoolProfile(
    id: id,
    appUserId: 'app-user-a',
    studentId: '20260001',
  );
}

LocalSchoolCredentialVault _vault(
  LocalSchoolProfile profile,
  AppSecretStore secureStore,
  String fingerprint,
) {
  return LocalSchoolCredentialVault(
    profile: profile,
    secureStore: secureStore,
    snapshotStore: YieldingPersonalSnapshotStore(
      accountFingerprint: fingerprint,
    ),
  );
}

class _InspectableSecretStore implements AppSecretStore {
  final Map<String, String> values = <String, String>{};
  String? failNextWriteKey;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failNextWriteKey == key) {
      failNextWriteKey = null;
      throw StateError('测试 manifest 写入失败');
    }
    values[key] = value;
  }
}
