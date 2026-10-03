import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/academic/storage/academic_credential_store.dart';
import 'package:shenliyuan/features/academic/storage/academic_session_artifact_vault.dart';
import 'package:shenliyuan/platform/contracts/secure_store.dart';

/// 9.2.4 在 Android 上把 Java 堆栈放进 PlatformException.details。
PlatformException badDecrypt() => PlatformException(
      code: 'Exception encountered',
      message: 'read',
      details: 'javax.crypto.BadPaddingException: error:1e000065:Cipher '
          'functions:OPENSSL_internal:BAD_DECRYPT',
    );

PlatformException keystoreBusy() => PlatformException(
      code: 'Exception encountered',
      message: 'read',
      details: 'java.security.KeyStoreException: Keystore busy',
    );

/// 可注入密码学损坏与临时故障的内存安全存储。
class _CorruptibleSecretStore implements AppSecretStore {
  final Map<String, String> values = <String, String>{};
  final Set<String> corruptedKeys = <String>{};
  final Set<String> transientFailingKeys = <String>{};

  @override
  Future<String?> read(String key) async {
    if (corruptedKeys.contains(key)) throw badDecrypt();
    if (transientFailingKeys.contains(key)) throw keystoreBusy();
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
    corruptedKeys.remove(key);
    transientFailingKeys.remove(key);
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
    corruptedKeys.remove(key);
    transientFailingKeys.remove(key);
  }
}

void main() {
  const identity = AcademicIdentityKey(
    appUserId: 'app-user',
    providerId: AcademicProviderId.syluUndergraduate,
    studentId: 'U-001',
  );

  ProviderSessionArtifact artifact(DateTime createdAt) =>
      ProviderSessionArtifact(
        providerId: identity.providerId,
        studentId: identity.studentId,
        artifactVersion: 1,
        createdAt: createdAt,
        validatedAt: createdAt,
        opaqueProviderState: const {
          'cookies': ['JSESSIONID=fixture; Path=/; Secure; HttpOnly'],
        },
      );

  group('AcademicSessionArtifactVault 密文损坏自愈', () {
    test('DEK 密文永久损坏时废弃该身份 Artifact 与 DEK，可重新建立会话', () async {
      final secrets = _CorruptibleSecretStore();
      final files = MemoryAcademicSessionArtifactFileBackend();
      final vault = AcademicSessionArtifactVault(
        identity: identity,
        secretStore: secrets,
        fileBackend: files,
      );
      final keyName = 'academic_session_dek_${identity.storageId}';
      await vault.write(artifact(DateTime.now().toUtc()));
      expect(await files.read(identity.storageId), isNotNull);

      // DEK 与 KeyStore 失配：读取自愈废弃 Artifact + DEK。
      secrets.corruptedKeys.add(keyName);
      expect(await vault.read(), isNull);
      expect(secrets.values.containsKey(keyName), isFalse);
      expect(await files.read(identity.storageId), isNull);

      // 重新登录后写入新 Artifact（新 DEK），恢复可读。
      final createdAt = DateTime.now().toUtc();
      await vault.write(artifact(createdAt));
      final restored = await vault.read();
      expect(restored, isNotNull);
      expect(restored!.createdAt, createdAt);
    });

    test('DEK 临时故障向上抛出，Artifact 保持原样可重试', () async {
      final secrets = _CorruptibleSecretStore();
      final files = MemoryAcademicSessionArtifactFileBackend();
      final vault = AcademicSessionArtifactVault(
        identity: identity,
        secretStore: secrets,
        fileBackend: files,
      );
      await vault.write(artifact(DateTime.now().toUtc()));
      final keyName = 'academic_session_dek_${identity.storageId}';
      secrets.transientFailingKeys.add(keyName);

      await expectLater(vault.read(), throwsA(isA<PlatformException>()));

      // 临时故障不得清理任何数据；故障恢复后可正常读取。
      expect(await files.read(identity.storageId), isNotNull);
      secrets.transientFailingKeys.remove(keyName);
      expect(await vault.read(), isNotNull);
    });
  });

  group('PlatformAcademicCredentialStore 密文损坏自愈', () {
    test('保存的教务密码永久损坏时删键并按未保存密码处理', () async {
      final secrets = _CorruptibleSecretStore();
      final store = PlatformAcademicCredentialStore(secretStore: secrets);
      await store.writeForIdentity(
        identity,
        const AcademicCredential(studentId: 'U-001', password: 's3cr3t'),
      );
      final keyName = 'academic_credential_v2_${identity.storageId}';
      secrets.corruptedKeys.add(keyName);

      // 密码永远取不回：删除坏键后视为未保存密码，引导重新输入一次。
      expect(await store.readForIdentity(identity), isNull);
      expect(secrets.values.containsKey(keyName), isFalse);

      // 重新保存后恢复正常。
      await store.writeForIdentity(
        identity,
        const AcademicCredential(studentId: 'U-001', password: 'new-pass'),
      );
      final restored = await store.readForIdentity(identity);
      expect(restored?.password, 'new-pass');
    });

    test('临时存储故障保持“安全存储暂不可用”，不误删凭据', () async {
      final secrets = _CorruptibleSecretStore();
      final store = PlatformAcademicCredentialStore(secretStore: secrets);
      await store.writeForIdentity(
        identity,
        const AcademicCredential(studentId: 'U-001', password: 's3cr3t'),
      );
      final keyName = 'academic_credential_v2_${identity.storageId}';
      secrets.transientFailingKeys.add(keyName);

      await expectLater(
        store.readForIdentity(identity),
        throwsA(isA<StateError>()),
      );
      expect(secrets.values[keyName], isNotNull);

      secrets.transientFailingKeys.remove(keyName);
      expect((await store.readForIdentity(identity))?.password, 's3cr3t');
    });
  });
}
