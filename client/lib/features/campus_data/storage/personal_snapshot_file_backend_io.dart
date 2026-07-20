import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'personal_snapshot_file_backend_base.dart';
import 'personal_snapshot_models.dart';

PersonalSnapshotFileBackend createPersonalSnapshotFileBackend() {
  return const IoPersonalSnapshotFileBackend();
}

class IoPersonalSnapshotFileBackend implements PersonalSnapshotFileBackend {
  const IoPersonalSnapshotFileBackend();

  static const int _maxSnapshotBytes = 20 * 1024 * 1024;

  Future<Directory> _rootDirectory() async {
    final supportDirectory = await getApplicationSupportDirectory();
    return Directory(path.join(supportDirectory.path, 'personal_vault'));
  }

  Future<Directory> _accountDirectory(String accountHash) async {
    final root = await _rootDirectory();
    return Directory(path.join(root.path, accountHash));
  }

  Future<File> _file(String accountHash, PersonalDataType type) async {
    final directory = await _accountDirectory(accountHash);
    return File(path.join(directory.path, '${type.storageValue}.bin'));
  }

  @override
  Future<Uint8List?> read({
    required String accountHash,
    required PersonalDataType type,
  }) async {
    final file = await _file(accountHash, type);
    if (!await file.exists()) return null;
    final length = await file.length();
    if (length <= 0 || length > _maxSnapshotBytes) {
      throw const PersonalSnapshotStoreException('个人数据密文文件大小异常');
    }
    return file.readAsBytes();
  }

  @override
  Future<void> write({
    required String accountHash,
    required PersonalDataType type,
    required Uint8List bytes,
  }) async {
    if (bytes.isEmpty || bytes.length > _maxSnapshotBytes) {
      throw const PersonalSnapshotStoreException('个人数据密文文件大小异常');
    }
    final target = await _file(accountHash, type);
    await target.parent.create(recursive: true);
    final suffix =
        '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
    final temporary = File('${target.path}.$suffix.tmp');
    final backup = File('${target.path}.$suffix.bak');
    var movedPrevious = false;
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      if (await target.exists()) {
        await target.rename(backup.path);
        movedPrevious = true;
      }
      await temporary.rename(target.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (!await target.exists() && movedPrevious && await backup.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    } finally {
      if (await temporary.exists()) await temporary.delete();
      if (await backup.exists() && await target.exists()) {
        await backup.delete();
      }
    }
  }

  @override
  Future<void> deleteType({
    required String accountHash,
    required PersonalDataType type,
  }) async {
    final file = await _file(accountHash, type);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> deleteUser(String accountHash) async {
    final directory = await _accountDirectory(accountHash);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  @override
  Future<void> deleteAll() async {
    final root = await _rootDirectory();
    if (await root.exists()) await root.delete(recursive: true);
  }
}
