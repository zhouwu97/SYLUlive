import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/academic/storage/academic_credential_store.dart';
import 'package:shenliyuan/platform/contracts/secure_store.dart';

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

    test('损坏 JSON 会被删除并按空凭据处理', () async {
      final secret = MemorySecretStore();
      final store = PlatformAcademicCredentialStore(secretStore: secret);
      // 通过一个已知键测试坏数据；实现会对错误内容执行安全删除。
      final rawKey = _credentialKey('app-a');
      await secret.write(rawKey, '{broken');
      expect(await store.read('app-a'), isNull);
      expect(await secret.read(rawKey), isNull);
    });

    test('Web store 不产生持久化凭据', () async {
      final store = PlatformAcademicCredentialStore(secretStore: WebSecretStore());
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
