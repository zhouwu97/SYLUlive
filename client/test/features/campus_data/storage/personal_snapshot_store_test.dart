import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';

import '../../../helpers/personal_snapshot_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AES-GCM 快照按 App 用户和来源账号隔离', () async {
    final secureStore = MemoryPersonalSnapshotSecureStore();
    final files = MemoryPersonalSnapshotFileBackend();
    final random = IncrementingRandomBytes();
    final owner = AesGcmAccountScopedSnapshotStore(
      appUserId: 'user-a',
      secureStore: secureStore,
      fileBackend: files,
      randomBytes: random.call,
    );

    await owner.write(
      type: PersonalDataType.erke,
      schemaVersion: 2,
      sourceSystem: 'erke',
      sourceAccountId: 'sid-a',
      payload: <String, dynamic>{'total': 12},
    );

    final sameOwner = await owner.read(
      type: PersonalDataType.erke,
      sourceSystem: 'erke',
      sourceAccountId: 'sid-a',
    );
    expect(sameOwner?.payload, <String, dynamic>{'total': 12});

    expect(
      await owner.read(
        type: PersonalDataType.erke,
        sourceSystem: 'erke',
        sourceAccountId: 'sid-b',
      ),
      isNull,
    );

    final otherUser = AesGcmAccountScopedSnapshotStore(
      appUserId: 'user-b',
      secureStore: secureStore,
      fileBackend: files,
      randomBytes: random.call,
    );
    expect(
      await otherUser.read(
        type: PersonalDataType.erke,
        sourceSystem: 'erke',
        sourceAccountId: 'sid-a',
      ),
      isNull,
    );

    final ownerFileKey = files.key(
      owner.accountFingerprint,
      PersonalDataType.erke,
    );
    final ownerFile = files.values[ownerFileKey]!;
    files.values[files.key(
      otherUser.accountFingerprint,
      PersonalDataType.erke,
    )] = Uint8List.fromList(
      ownerFile,
    );
    await expectLater(
      otherUser.read(
        type: PersonalDataType.erke,
        sourceSystem: 'erke',
        sourceAccountId: 'sid-a',
      ),
      throwsA(isA<PersonalSnapshotStoreException>()),
    );

    final storedText = utf8.decode(files.values[ownerFileKey]!);
    expect(storedText, isNot(contains('"total":12')));
    expect(storedText, isNot(contains('sid-a')));
  });

  test('篡改密文后认证失败，不能返回部分数据', () async {
    final secureStore = MemoryPersonalSnapshotSecureStore();
    final files = MemoryPersonalSnapshotFileBackend();
    final store = AesGcmAccountScopedSnapshotStore(
      appUserId: 'user-a',
      secureStore: secureStore,
      fileBackend: files,
      randomBytes: IncrementingRandomBytes().call,
    );
    await store.write(
      type: PersonalDataType.physical,
      schemaVersion: 2,
      sourceSystem: 'physical',
      sourceAccountId: 'sid-a',
      payload: <String, dynamic>{'score': 90},
    );

    final fileKey = files.values.keys.single;
    final envelope =
        jsonDecode(utf8.decode(files.values[fileKey]!)) as Map<String, dynamic>;
    final ciphertext = base64Decode(envelope['ciphertext'] as String);
    ciphertext[ciphertext.length ~/ 2] ^= 0x01;
    envelope['ciphertext'] = base64Encode(ciphertext);
    files.values[fileKey] = Uint8List.fromList(
      utf8.encode(jsonEncode(envelope)),
    );

    await expectLater(
      store.read(
        type: PersonalDataType.physical,
        sourceSystem: 'physical',
        sourceAccountId: 'sid-a',
      ),
      throwsA(isA<PersonalSnapshotStoreException>()),
    );
  });

  test('读取阶段设备盐缺失时失败关闭且不自动重建', () async {
    final secureStore = MemoryPersonalSnapshotSecureStore();
    final files = MemoryPersonalSnapshotFileBackend();
    final store = AesGcmAccountScopedSnapshotStore(
      appUserId: 'user-a',
      secureStore: secureStore,
      fileBackend: files,
      randomBytes: IncrementingRandomBytes().call,
    );
    await store.write(
      type: PersonalDataType.erke,
      schemaVersion: 2,
      sourceSystem: 'erke',
      sourceAccountId: 'sid-a',
      payload: <String, dynamic>{'value': 1},
    );
    final saltKey = secureStore.values.keys.singleWhere(
      (key) => key.startsWith('ai_personal_vault_device_salt/'),
    );
    await secureStore.delete(saltKey);

    await expectLater(
      store.read(
        type: PersonalDataType.erke,
        sourceSystem: 'erke',
        sourceAccountId: 'sid-a',
      ),
      throwsA(isA<PersonalSnapshotStoreException>()),
    );
    expect(secureStore.values.containsKey(saltKey), isFalse);
  });

  test('clearUser 先删除账号密钥并清除全部账号密文', () async {
    final secureStore = MemoryPersonalSnapshotSecureStore();
    final files = MemoryPersonalSnapshotFileBackend();
    final store = AesGcmAccountScopedSnapshotStore(
      appUserId: 'user-a',
      secureStore: secureStore,
      fileBackend: files,
      randomBytes: IncrementingRandomBytes().call,
    );
    await store.write(
      type: PersonalDataType.erke,
      schemaVersion: 2,
      sourceSystem: 'erke',
      sourceAccountId: 'sid-a',
      payload: <String, dynamic>{'value': 1},
    );
    await store.write(
      type: PersonalDataType.physical,
      schemaVersion: 2,
      sourceSystem: 'physical',
      sourceAccountId: 'sid-a',
      payload: <String, dynamic>{'value': 2},
    );

    await store.clearUser();

    expect(
      secureStore.values.keys.where(
        (key) => key.startsWith('ai_personal_vault_key/'),
      ),
      isEmpty,
    );
    expect(files.values, isEmpty);
    expect(
      await store.read(
        type: PersonalDataType.erke,
        sourceSystem: 'erke',
        sourceAccountId: 'sid-a',
      ),
      isNull,
    );
  });
}
