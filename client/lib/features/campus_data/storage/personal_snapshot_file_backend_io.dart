import 'dart:async';
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
  })  : _supportDirectoryLoader =
            supportDirectoryLoader ?? getApplicationSupportDirectory,
        _onBackupMoved = onBackupMoved;

  static const int _maxSnapshotBytes = 20 * 1024 * 1024;
  static final RegExp _accountHashPattern = RegExp(r'^[a-f0-9]{64}$');

  // 后端实例可能随页面或依赖注入容器重建，队列必须跨实例共享。
  static final Map<String, Future<void>> _targetOperationTails =
      <String, Future<void>>{};
  static final Map<String, _AsyncReadWriteGate> _accountOperationGates =
      <String, _AsyncReadWriteGate>{};
  static final _AsyncReadWriteGate _globalOperationGate = _AsyncReadWriteGate();

  final Future<Directory> Function() _supportDirectoryLoader;
  final Future<void> Function()? _onBackupMoved;

  Future<Directory> _rootDirectory() async {
    final supportDirectory = await _supportDirectoryLoader();
    return Directory(path.join(supportDirectory.path, 'personal_vault'));
  }

  Future<Directory> _accountDirectory(String accountHash) async {
    if (!_accountHashPattern.hasMatch(accountHash)) {
      throw const PersonalSnapshotStoreException('个人数据账号命名空间无效');
    }
    final root = await _rootDirectory();
    return Directory(path.join(root.path, accountHash));
  }

  Future<File> _file(String accountHash, PersonalDataType type) async {
    final directory = await _accountDirectory(accountHash);
    return File(path.join(directory.path, '${type.storageValue}.bin'));
  }

  _AsyncReadWriteGate _accountOperationGate(String accountHash) {
    return _accountOperationGates.putIfAbsent(
      accountHash,
      _AsyncReadWriteGate.new,
    );
  }

  Future<T> _runTargetOperation<T>({
    required String accountHash,
    required PersonalDataType type,
    required Future<T> Function(File target) operation,
  }) async {
    final target = await _file(accountHash, type);
    return _globalOperationGate.runRead(() {
      return _accountOperationGate(accountHash).runRead(() {
        return _serializeTarget(target, () => operation(target));
      });
    });
  }

  Future<T> _serializeTarget<T>(
    File target,
    Future<T> Function() operation,
  ) {
    final key = path.normalize(path.absolute(target.path));
    final previous = _targetOperationTails[key] ?? Future<void>.value();
    final guarded = previous.then<T>((_) => Future<T>.sync(operation));
    final tail = guarded.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _targetOperationTails[key] = tail;

    return guarded.whenComplete(() {
      if (identical(_targetOperationTails[key], tail)) {
        _targetOperationTails.remove(key);
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
    final directory = await _accountDirectory(accountHash);
    await _globalOperationGate.runRead(() {
      return _accountOperationGate(accountHash).runWrite(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
    });
  }

  @override
  Future<void> deleteAll() async {
    final root = await _rootDirectory();
    await _globalOperationGate.runWrite(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
  }

  /// 只恢复当前账号目录下由本后端生成的中断写入备份文件。
  /// 调用方必须已持有 target 的串行队列。
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

/// 允许多个普通操作并行，但让删除操作等待已有操作后独占执行。
class _AsyncReadWriteGate {
  Future<void> _writerTail = Future<void>.value();
  int _activeReaders = 0;
  Completer<void>? _readersDrained;

  Future<T> runRead<T>(Future<T> Function() operation) {
    final priorWriter = _writerTail;
    _activeReaders++;

    return Future<T>.sync(() async {
      await priorWriter;
      return operation();
    }).whenComplete(_releaseReader);
  }

  Future<T> runWrite<T>(Future<T> Function() operation) {
    final priorWriter = _writerTail;
    final priorReaders = _activeReaders == 0
        ? Future<void>.value()
        : (_readersDrained ??= Completer<void>()).future;
    final releaseWriter = Completer<void>();
    _writerTail = releaseWriter.future;

    return Future<T>.sync(() async {
      await priorWriter;
      await priorReaders;
      return operation();
    }).whenComplete(() {
      if (!releaseWriter.isCompleted) releaseWriter.complete();
    });
  }

  void _releaseReader() {
    _activeReaders--;
    if (_activeReaders == 0) {
      final readersDrained = _readersDrained;
      _readersDrained = null;
      if (readersDrained != null && !readersDrained.isCompleted) {
        readersDrained.complete();
      }
    }
  }
}
