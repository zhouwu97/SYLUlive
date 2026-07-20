import 'dart:typed_data';

import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_file_backend_base.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';

class MemoryPersonalSnapshotSecureStore implements PersonalSnapshotSecureStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<Map<String, String>> readAll() async =>
      Map<String, String>.from(values);

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class MemoryPersonalSnapshotFileBackend implements PersonalSnapshotFileBackend {
  final Map<String, Uint8List> values = <String, Uint8List>{};
  bool failWrites = false;

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
    if (failWrites) throw StateError('写入失败');
    values[key(accountHash, type)] = Uint8List.fromList(bytes);
  }
}

/// 每次读写均让出事件循环，用于稳定复现上层读改写竞争。
class YieldingPersonalSnapshotStore implements AccountScopedSnapshotStore {
  YieldingPersonalSnapshotStore({
    this.accountFingerprint = 'concurrent-test-account',
  });

  @override
  final String accountFingerprint;

  PersonalSnapshot? _snapshot;

  @override
  Future<void> clearUser() async {
    await Future<void>.delayed(Duration.zero);
    _snapshot = null;
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> deleteType(PersonalDataType type) async {
    await Future<void>.delayed(Duration.zero);
    if (_snapshot?.type == type) _snapshot = null;
  }

  @override
  Future<PersonalSnapshot?> read({
    required PersonalDataType type,
    required String sourceSystem,
    required String sourceAccountId,
  }) async {
    final snapshot = _snapshot;
    await Future<void>.delayed(Duration.zero);
    if (snapshot == null || snapshot.type != type) return null;
    return PersonalSnapshot(
      appUserFingerprint: snapshot.appUserFingerprint,
      sourceAccountFingerprint: snapshot.sourceAccountFingerprint,
      type: snapshot.type,
      schemaVersion: snapshot.schemaVersion,
      encryptionVersion: snapshot.encryptionVersion,
      fetchedAt: snapshot.fetchedAt,
      expiresAt: snapshot.expiresAt,
      contentHash: snapshot.contentHash,
      payload: Map<String, dynamic>.from(snapshot.payload),
    );
  }

  @override
  Future<void> write({
    required PersonalDataType type,
    required int schemaVersion,
    required String sourceSystem,
    required String sourceAccountId,
    required Map<String, dynamic> payload,
    DateTime? fetchedAt,
    DateTime? expiresAt,
  }) async {
    final next = PersonalSnapshot(
      appUserFingerprint: accountFingerprint,
      sourceAccountFingerprint: 'test-source',
      type: type,
      schemaVersion: schemaVersion,
      encryptionVersion: 1,
      fetchedAt: fetchedAt ?? DateTime.now().toUtc(),
      expiresAt: expiresAt,
      contentHash: 'test-content-hash',
      payload: Map<String, dynamic>.from(payload),
    );
    await Future<void>.delayed(Duration.zero);
    _snapshot = next;
  }
}

class IncrementingRandomBytes {
  int _seed = 0;

  Uint8List call(int length) {
    final result = Uint8List(length);
    for (var index = 0; index < length; index++) {
      result[index] = (_seed + index + 1) & 0xff;
    }
    _seed = (_seed + length) & 0xff;
    return result;
  }
}
