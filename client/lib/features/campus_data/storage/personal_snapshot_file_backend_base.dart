import 'dart:typed_data';

import 'personal_snapshot_models.dart';

abstract interface class PersonalSnapshotFileBackend {
  Future<Uint8List?> read({
    required String accountHash,
    required PersonalDataType type,
  });

  Future<void> write({
    required String accountHash,
    required PersonalDataType type,
    required Uint8List bytes,
  });

  Future<void> deleteType({
    required String accountHash,
    required PersonalDataType type,
  });

  Future<void> deleteUser(String accountHash);

  Future<void> deleteAll();
}
