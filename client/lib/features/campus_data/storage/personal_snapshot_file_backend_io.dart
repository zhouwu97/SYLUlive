import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'personal_snapshot_file_backend_base.dart';
import 'personal_snapshot_models.dart';

PersonalSnapshotFileBackend createPersonalSnapshotFileBackend() {
  return IoPersonalSnapshotFileBackend();
}

class IoPersonalSnapshotFileBackend implements PersonalSnapshotFileBackend {
  IoPersonalSnapshotFileBackend({
    Future<Directory> Function()? supportDirectoryLoader,
    Future<void> Function()? onBackupMoved,
    void Function()? onVaultOperationQueued,
  })  : _supportDirectoryLoader =
            supportDirectoryLoader ?? getApplicationSupportDirectory,
        _onBackupMoved = onBackupMoved,
        _onVaultOperationQueued = onVaultOperationQueued;

  static const int _maxSnapshotBytes = 20 * 1024 * 1024;
  static final RegExp _accountHashPattern = RegExp(r'^[a-f0-9]{64}$');

  // 后端实例可能随页面或依赖注入容器重建，队列必须跨实例共享。
  // 保险箱文件很小，按根目录串行化比异步读写锁更容易证明正确。
  static final Map<String, Future<void>> _vaultOperationTails =
      <String, Future<void>>{};

  final Future<Directory> Function() _supportDirectoryLoader;
  final Future<void> Function()? _onBackupMoved;
  final void Function()? _onVaultOperationQueued;

  Future<Directory> _rootDirectory() async {
    final supportDirectory = await _supportDirectoryLoader();
    return Directory(path.join(supportDirectory.path, 'personal_vault'));
  }

  void _validateAccountHash(String accountHash) {
    if (!_accountHashPattern.hasMatch(accountHash)) {
      throw const PersonalSnapshotStoreException('个人数据账号命名空间无效');
    }
  }

  Future<T> _runTargetOperation<T>({
    required String accountHash,
    required PersonalDataType type,
    required Future<T> Function(File target) operation,
  }) async {
    _validateAccountHash(accountHash);
    final root = await _rootDirectory();
    final target = File(
      path.join(root.path, accountHash, '${type.storageValue}.bin'),
    );
    return _serializeVault(root, () => operation(target));
  }

  Future<T> _runVaultOperation<T>(
      Future<T> Function(Directory root) operation) async {
    final root = await _rootDirectory();
    return _serializeVault(root, () => operation(root));
  }

  Future<T> _serializeVault<T>(
    Directory root,
    Future<T> Function() operation,
  ) {
    final key = path.normalize(path.absolute(root.path));
    final previous = _vaultOperationTails[key] ?? Future<void>.value();
    final guarded = previous.then<T>((_) => Future<T>.sync(operation));
    final tail = guarded.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _vaultOperationTails[key] = tail;
    // 仅用于并发回归测试，正式构造路径中始终为 null。
    _onVaultOperationQueued?.call();

    return guarded.whenComplete(() {
      if (identical(_vaultOperationTails[key], tail)) {
        _vaultOperationTails.remove(key);
      }
    });
  }

  @override
  Future<Uint8List?> read({
    required String accountHash,
    required PersonalDataType type,
  }) async {
    return _runTargetOperation(
      accountHash: accountHash,
      type: type,
      operation: (file) async {
        await _recoverForReadUnlocked(file);
        if (!await file.exists()) return null;
        final length = await file.length();
        if (length <= 0 || length > _maxSnapshotBytes) {
          throw const PersonalSnapshotStoreException('个人数据密文文件大小异常');
        }
        return file.readAsBytes();
      },
    );
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
    await _runTargetOperation(
      accountHash: accountHash,
      type: type,
      operation: (target) async {
        await target.parent.create(recursive: true);
        await _recoverForReadUnlocked(target);
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
            // 仅用于回归测试，在正式构造路径中始终为 null。
            await _onBackupMoved?.call();
          }
          await temporary.rename(target.path);
          if (await backup.exists()) await backup.delete();
        } catch (_) {
          if (!await target.exists() &&
              movedPrevious &&
              await backup.exists()) {
            await backup.rename(target.path);
          }
          rethrow;
        } finally {
          if (await temporary.exists()) await temporary.delete();
          if (await backup.exists() && await target.exists()) {
            await backup.delete();
          }
        }
      },
    );
  }

  @override
  Future<void> deleteType({
    required String accountHash,
    required PersonalDataType type,
  }) async {
    await _runTargetOperation(
      accountHash: accountHash,
      type: type,
      operation: _deleteSnapshotFiles,
    );
  }

  @override
  Future<void> deleteUser(String accountHash) async {
    _validateAccountHash(accountHash);
    await _runVaultOperation((root) async {
      final directory = Directory(path.join(root.path, accountHash));
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
  }

  @override
  Future<void> deleteAll() async {
    await _runVaultOperation((root) async {
      if (await root.exists()) await root.delete(recursive: true);
    });
  }

  /// 只恢复当前账号目录下由本后端生成的中断写入备份文件。
  /// 调用方必须已持有保险箱根目录的串行队列。
  Future<void> _recoverForReadUnlocked(File target) async {
    final backups = await _findArtifacts(target, 'bak');
    final temporaries = await _findArtifacts(target, 'tmp');

    if (await target.exists()) {
      // 正式文件已经存在时始终优先使用它，遗留文件只是可安全清理的残留。
      await _deleteFilesBestEffort(<File>[...backups, ...temporaries]);
      return;
    }

    if (backups.length > 1) {
      throw const PersonalSnapshotStoreException('个人数据备份文件数量异常，已拒绝恢复');
    }

    if (backups.isEmpty) {
      // 临时文件没有完成原子替换，不能被视为可用密文。
      await _deleteFilesBestEffort(temporaries);
      return;
    }

    final backup = backups.single;
    try {
      await backup.rename(target.path);
    } on FileSystemException {
      // 若并发写入已创建正式文件，正式文件优先，避免恢复操作覆盖新数据。
      if (!await target.exists()) {
        throw const PersonalSnapshotStoreException('个人数据备份恢复失败');
      }
    }
    await _deleteFilesBestEffort(temporaries);
  }

  Future<List<File>> _findArtifacts(File target, String extension) async {
    final directory = target.parent;
    if (!await directory.exists()) return <File>[];

    final targetName = path.basename(target.path);
    final artifactPattern = RegExp(
      '^${RegExp.escape(targetName)}\\.\\d+-\\d+\\.${RegExp.escape(extension)}\$',
    );
    final artifacts = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File &&
          artifactPattern.hasMatch(path.basename(entity.path))) {
        artifacts.add(entity);
      }
    }
    return artifacts;
  }

  Future<void> _deleteSnapshotFiles(File target) async {
    final backups = await _findArtifacts(target, 'bak');
    final temporaries = await _findArtifacts(target, 'tmp');
    for (final file in <File>[target, ...backups, ...temporaries]) {
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> _deleteFilesBestEffort(Iterable<File> files) async {
    for (final file in files) {
      try {
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // 残留文件清理失败不影响已验证正式密文的读取。
      }
    }
  }
}
