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
  }) async => values.remove(key(accountHash, type));

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
