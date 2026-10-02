import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_file_backend_base.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';

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

class _CorruptiblePersonalSecretStore implements PersonalSnapshotSecureStore {
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

class _MemoryFileBackend implements PersonalSnapshotFileBackend {
  final Map<String, Uint8List> values = <String, Uint8List>{};

  String key(String accountHash, PersonalDataType type) =>
      '$accountHash/${type.storageValue}';

  @override
  Future<void> deleteAll() async => values.clear();

  @override
  Future<void> deleteType({
    required String accountHash,
    required PersonalDataType type,
  }) async =>
      values.remove(key(accountHash, type));

  @override
  Future<void> deleteUser(String accountHash) async {
    values.removeWhere((key, _) => key.startsWith('$accountHash/'));
  }

  @override
  Future<Uint8List?> read({
    required String accountHash,
    required PersonalDataType type,
  }) async {
    final value = values[key(accountHash, type)];
    return value == null ? null : Uint8List.fromList(value);
  }

  @override
  Future<void> write({
    required String accountHash,
    required PersonalDataType type,
    required Uint8List bytes,
  }) async {
    values[key(accountHash, type)] = Uint8List.fromList(bytes);
  }
}

AesGcmAccountScopedSnapshotStore _store(
  _CorruptiblePersonalSecretStore secrets,
  _MemoryFileBackend files,
) {
  var seed = 0;
  return AesGcmAccountScopedSnapshotStore(
    appUserId: 'user-a',
    identityNamespace: 'identity-ns',
    secureStore: secrets,
    fileBackend: files,
    randomBytes: (length) {
      final result = Uint8List(length);
      for (var index = 0; index < length; index++) {
        result[index] = (seed + index + 1) & 0xff;
      }
      seed += length;
      return result;
    },
  );
}

void main() {
  Future<void> writeSchedule(AesGcmAccountScopedSnapshotStore store) {
    return store.write(
      type: PersonalDataType.schedule,
      schemaVersion: 1,
      sourceSystem: 'edu',
      sourceAccountId: 'sid-a',
      payload: <String, dynamic>{'courses': 3},
    );
  }

  test('单身份 DEK 损坏时废弃该 namespace 密文，可重新拉取并重建缓存', () async {
    final secrets = _CorruptiblePersonalSecretStore();
    final files = _MemoryFileBackend();
    final store = _store(secrets, files);
    final dekKey = 'ai_personal_vault_key/${store.storageNamespace}/v1';
    await writeSchedule(store);
    expect(
      files.values.containsKey(
        files.key(store.storageNamespace, PersonalDataType.schedule),
      ),
      isTrue,
    );

    // DEK 密文永久损坏：读取自愈清理并返回无缓存。
    secrets.corruptedKeys.add(dekKey);
    expect(
      await store.read(
        type: PersonalDataType.schedule,
        sourceSystem: 'edu',
        sourceAccountId: 'sid-a',
      ),
      isNull,
    );
    expect(secrets.values.containsKey(dekKey), isFalse);
    expect(
      files.values.containsKey(
        files.key(store.storageNamespace, PersonalDataType.schedule),
      ),
      isFalse,
    );

    // 重新拉取后写入新快照（新 DEK），恢复可读。
    await writeSchedule(store);
    final restored = await store.read(
      type: PersonalDataType.schedule,
      sourceSystem: 'edu',
      sourceAccountId: 'sid-a',
    );
    expect(restored?.payload, <String, dynamic>{'courses': 3});
  });

  test('设备盐损坏时清空全部 Vault 并重建盐，旧密文不出现幽灵缓存', () async {
    final secrets = _CorruptiblePersonalSecretStore();
    final files = _MemoryFileBackend();
    final store = _store(secrets, files);
    await writeSchedule(store);
    expect(files.values, isNotEmpty);

    // salt 损坏在读取来源指纹时暴露：本次报设备盐不可用，同时已自愈清理。
    secrets.corruptedKeys.add('ai_personal_vault_device_salt/v1');
    await expectLater(
      store.read(
        type: PersonalDataType.schedule,
        sourceSystem: 'edu',
        sourceAccountId: 'sid-a',
      ),
      throwsA(isA<PersonalSnapshotStoreException>()),
    );
    expect(secrets.values.containsKey('ai_personal_vault_device_salt/v1'),
        isFalse);
    // 全部旧密文已被清除：换盐后不可能出现“文件在但指纹不匹配”的幽灵缓存。
    expect(files.values, isEmpty);

    // 重试读取即为无缓存；重新拉取后以新 salt 正常写入并读取。
    expect(
      await store.read(
        type: PersonalDataType.schedule,
        sourceSystem: 'edu',
        sourceAccountId: 'sid-a',
      ),
      isNull,
    );
    await writeSchedule(store);
    final restored = await store.read(
      type: PersonalDataType.schedule,
      sourceSystem: 'edu',
      sourceAccountId: 'sid-a',
    );
    expect(restored?.payload, <String, dynamic>{'courses': 3});
    expect(secrets.values.containsKey('ai_personal_vault_device_salt/v1'),
        isTrue);
  });

  test('临时存储故障保持异常可重试，不清理任何数据', () async {
    final secrets = _CorruptiblePersonalSecretStore();
    final files = _MemoryFileBackend();
    final store = _store(secrets, files);
    final dekKey = 'ai_personal_vault_key/${store.storageNamespace}/v1';
    await writeSchedule(store);
    secrets.transientFailingKeys.add(dekKey);

    await expectLater(
      store.read(
        type: PersonalDataType.schedule,
        sourceSystem: 'edu',
        sourceAccountId: 'sid-a',
      ),
      throwsA(isA<PersonalSnapshotStoreException>()),
    );
    expect(files.values, isNotEmpty);

    secrets.transientFailingKeys.remove(dekKey);
    final restored = await store.read(
      type: PersonalDataType.schedule,
      sourceSystem: 'edu',
      sourceAccountId: 'sid-a',
    );
    expect(restored?.payload, <String, dynamic>{'courses': 3});
  });
}
