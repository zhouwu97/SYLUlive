import 'dart:typed_data';

import 'personal_snapshot_file_backend_base.dart';
import 'personal_snapshot_models.dart';

PersonalSnapshotFileBackend createPersonalSnapshotFileBackend() {
  return const UnsupportedPersonalSnapshotFileBackend();
}

class UnsupportedPersonalSnapshotFileBackend
    implements PersonalSnapshotFileBackend {
  const UnsupportedPersonalSnapshotFileBackend();

  Never _unsupported() {
    throw const PersonalSnapshotStoreException('当前平台不支持本地个人数据保险箱');
  }

  @override
  Future<void> deleteAll() async => _unsupported();

  @override
  Future<void> deleteType({
    required String accountHash,
    required PersonalDataType type,
  }) async => _unsupported();

  @override
  Future<void> deleteUser(String accountHash) async => _unsupported();

  @override
  Future<Uint8List?> read({
    required String accountHash,
    required PersonalDataType type,
  }) async => _unsupported();

  @override
  Future<void> write({
    required String accountHash,
    required PersonalDataType type,
    required Uint8List bytes,
  }) async => _unsupported();
}
