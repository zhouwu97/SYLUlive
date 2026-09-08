import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/academic/storage/academic_credential_store.dart';
import 'package:shenliyuan/platform/contracts/secure_store.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';

void main() {
  group('PlatformAcademicCredentialStore', () {
    test('按 App 用户写入、读取和删除凭据', () async {
      final secret = MemorySecretStore();
      final store = PlatformAcademicCredentialStore(secretStore: secret);
      const credential = AcademicCredential(
        studentId: '2403000001',
        password: 's3cr3t',
      );

      await store.write('app-a', credential);

      expect(await store.read('app-a'), isNotNull);
      expect((await store.read('app-a'))!.studentId, credential.studentId);
      expect(await store.read('app-b'), isNull);
      await store.delete('app-a');
      expect(await store.read('app-a'), isNull);
    });

    test('损坏 JSON 不参与认证但保留安全存储原文', () async {
      final secret = MemorySecretStore();
      final store = PlatformAcademicCredentialStore(secretStore: secret);
      // 读取错误不能隐式擦除用户已选择保留的密码材料。
      final rawKey = _credentialKey('app-a');
      await secret.write(rawKey, '{broken');
      await expectLater(store.read('app-a'), throwsStateError);
      expect(await secret.read(rawKey), '{broken');
    });

    test('身份级异常凭据保留到用户显式清除', () async {
      final secret = MemorySecretStore();
      final store = PlatformAcademicCredentialStore(secretStore: secret);
      const identity = AcademicIdentityKey(
          appUserId: 'app-a',
          providerId: AcademicProviderId.syluGraduate,
          studentId: 'fixture');
      final key = 'academic_credential_v2_${identity.storageId}';
      await secret.write(key, '{broken');
      await expectLater(store.readForIdentity(identity), throwsStateError);
      expect(await secret.read(key), '{broken');
      await store.deleteForIdentity(identity);
      expect(await secret.read(key), isNull);
    });

    test('Web store 不产生持久化凭据', () async {
      final store =
          PlatformAcademicCredentialStore(secretStore: WebSecretStore());
      await store.write(
        'app-a',
        const AcademicCredential(studentId: '2403000001', password: 's3cr3t'),
      );
      expect(await store.read('app-a'), isNull);
    });
  });
}

String _credentialKey(String appUserId) =>
    'academic_credential_v1_${sha256.convert(utf8.encode(appUserId))}';
