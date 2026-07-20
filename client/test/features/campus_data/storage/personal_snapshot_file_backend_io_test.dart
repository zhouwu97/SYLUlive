import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_file_backend_io.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';

import '../../../helpers/personal_snapshot_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory supportDirectory;
  late IoPersonalSnapshotFileBackend backend;

  setUp(() async {
    supportDirectory = await Directory.systemTemp.createTemp(
      'sylu-personal-vault-test-',
    );
    backend = IoPersonalSnapshotFileBackend(
      supportDirectoryLoader: () async => supportDirectory,
    );
  });

  tearDown(() async {
    if (await supportDirectory.exists()) {
      await supportDirectory.delete(recursive: true);
    }
  });

  test('正式文件缺失时仅恢复当前账号的唯一合法备份', () async {
    const accountHash = _accountA;
    final target = await _targetFile(
      supportDirectory,
      accountHash,
      PersonalDataType.physical,
    );
    await target.parent.create(recursive: true);
    final backup = File('${target.path}.1-2.bak');
    final temporary = File('${target.path}.3-4.tmp');
    await backup.writeAsBytes(<int>[1, 2, 3], flush: true);
    await temporary.writeAsBytes(<int>[9], flush: true);

    expect(
      await backend.read(
        accountHash: accountHash,
        type: PersonalDataType.physical,
      ),
      Uint8List.fromList(<int>[1, 2, 3]),
    );
    expect(await target.exists(), isTrue);
    expect(await backup.exists(), isFalse);
    expect(await temporary.exists(), isFalse);
  });

  test('正式文件存在时优先使用正式文件并清理合法备份', () async {
    final target = await _targetFile(
      supportDirectory,
      _accountA,
      PersonalDataType.erke,
    );
    await target.parent.create(recursive: true);
    final backup = File('${target.path}.1-2.bak');
    await target.writeAsBytes(<int>[7, 8], flush: true);
    await backup.writeAsBytes(<int>[1, 2], flush: true);

    expect(
      await backend.read(accountHash: _accountA, type: PersonalDataType.erke),
      Uint8List.fromList(<int>[7, 8]),
    );
    expect(await backup.exists(), isFalse);
  });

  test('只有临时文件时不将其视为正式密文', () async {
    final target = await _targetFile(
      supportDirectory,
      _accountA,
      PersonalDataType.erke,
    );
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.1-2.tmp');
    await temporary.writeAsBytes(<int>[1, 2, 3], flush: true);

    expect(
      await backend.read(accountHash: _accountA, type: PersonalDataType.erke),
      isNull,
    );
    expect(await temporary.exists(), isFalse);
  });

  test('不匹配后端生成规则的备份文件不会被扫描或恢复', () async {
    final target = await _targetFile(
      supportDirectory,
      _accountA,
      PersonalDataType.erke,
    );
    await target.parent.create(recursive: true);
    final unrelatedBackup = File('${target.path}.manual.bak');
    await unrelatedBackup.writeAsBytes(<int>[1, 2, 3], flush: true);

    expect(
      await backend.read(
        accountHash: _accountA,
        type: PersonalDataType.erke,
      ),
      isNull,
    );
    expect(await unrelatedBackup.exists(), isTrue);
  });

  test('无效账号命名空间不能访问保险箱目录', () async {
    await expectLater(
      backend.read(
        accountHash: '../$_accountA',
        type: PersonalDataType.erke,
      ),
      throwsA(isA<PersonalSnapshotStoreException>()),
    );
  });

  test('多个合法备份时失败关闭且不恢复任一备份', () async {
    final target = await _targetFile(
      supportDirectory,
      _accountA,
      PersonalDataType.erke,
    );
    await target.parent.create(recursive: true);
    final firstBackup = File('${target.path}.1-2.bak');
    final secondBackup = File('${target.path}.3-4.bak');
    await firstBackup.writeAsBytes(<int>[1], flush: true);
    await secondBackup.writeAsBytes(<int>[2], flush: true);

    await expectLater(
      backend.read(accountHash: _accountA, type: PersonalDataType.erke),
      throwsA(isA<PersonalSnapshotStoreException>()),
    );
    expect(await target.exists(), isFalse);
    expect(await firstBackup.exists(), isTrue);
    expect(await secondBackup.exists(), isTrue);
  });

  test('其他账号目录中的备份不能恢复到当前账号', () async {
    final otherTarget = await _targetFile(
      supportDirectory,
      _accountB,
      PersonalDataType.physical,
    );
    await otherTarget.parent.create(recursive: true);
    final otherBackup = File('${otherTarget.path}.1-2.bak');
    await otherBackup.writeAsBytes(<int>[1, 2, 3], flush: true);

    expect(
      await backend.read(
        accountHash: _accountA,
        type: PersonalDataType.physical,
      ),
      isNull,
    );
    expect(await otherBackup.exists(), isTrue);
  });

  test('恢复后的密文仍由 AES-GCM 认证，篡改备份会被拒绝', () async {
    final secureStore = MemoryPersonalSnapshotSecureStore();
    final store = AesGcmAccountScopedSnapshotStore(
      appUserId: 'user-a',
      secureStore: secureStore,
      fileBackend: backend,
      randomBytes: IncrementingRandomBytes().call,
    );
    await store.write(
      type: PersonalDataType.erke,
      schemaVersion: 2,
      sourceSystem: 'erke',
      sourceAccountId: 'sid-a',
      payload: <String, dynamic>{'score': 12},
    );
    final target = await _targetFile(
      supportDirectory,
      store.accountFingerprint,
      PersonalDataType.erke,
    );
    final backup = File('${target.path}.1-2.bak');
    await target.rename(backup.path);
    final bytes = await backup.readAsBytes();
    bytes[bytes.length ~/ 2] ^= 0x01;
    await backup.writeAsBytes(bytes, flush: true);

    await expectLater(
      store.read(
        type: PersonalDataType.erke,
        sourceSystem: 'erke',
        sourceAccountId: 'sid-a',
      ),
      throwsA(isA<PersonalSnapshotStoreException>()),
    );
    expect(await target.exists(), isTrue);
  });

  test('不同后端实例的活跃写入期间读取会等待并返回新数据', () async {
    final backupMoved = Completer<void>();
    final allowWriteToContinue = Completer<void>();
    final writer = IoPersonalSnapshotFileBackend(
      supportDirectoryLoader: () async => supportDirectory,
      onBackupMoved: () async {
        backupMoved.complete();
        await allowWriteToContinue.future;
      },
    );
    final reader = IoPersonalSnapshotFileBackend(
      supportDirectoryLoader: () async => supportDirectory,
    );
    const type = PersonalDataType.erke;

    await writer.write(
      accountHash: _accountA,
      type: type,
      bytes: Uint8List.fromList(<int>[1]),
    );
    final write = writer.write(
      accountHash: _accountA,
      type: type,
      bytes: Uint8List.fromList(<int>[2]),
    );
    await backupMoved.future;

    var readCompleted = false;
    final read = reader.read(accountHash: _accountA, type: type).then((value) {
      readCompleted = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(readCompleted, isFalse);

    allowWriteToContinue.complete();
    await write;
    expect(await read, Uint8List.fromList(<int>[2]));
    final target = await _targetFile(supportDirectory, _accountA, type);
    expect(await target.exists(), isTrue);
    await _expectNoArtifacts(supportDirectory, _accountA, type);
  });

  test('删除类型数据会等待活跃写入并清除完整写入结果', () async {
    final backupMoved = Completer<void>();
    final allowWriteToContinue = Completer<void>();
    final writer = IoPersonalSnapshotFileBackend(
      supportDirectoryLoader: () async => supportDirectory,
      onBackupMoved: () async {
        backupMoved.complete();
        await allowWriteToContinue.future;
      },
    );
    final deleter = IoPersonalSnapshotFileBackend(
      supportDirectoryLoader: () async => supportDirectory,
    );
    const type = PersonalDataType.physical;

    await writer.write(
      accountHash: _accountA,
      type: type,
      bytes: Uint8List.fromList(<int>[1]),
    );
    final write = writer.write(
      accountHash: _accountA,
      type: type,
      bytes: Uint8List.fromList(<int>[2]),
    );
    await backupMoved.future;

    var deleteCompleted = false;
    final delete =
        deleter.deleteType(accountHash: _accountA, type: type).then((_) {
      deleteCompleted = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(deleteCompleted, isFalse);

    allowWriteToContinue.complete();
    await write;
    await delete;
    expect(await deleter.read(accountHash: _accountA, type: type), isNull);
    final target = await _targetFile(supportDirectory, _accountA, type);
    expect(await target.exists(), isFalse);
    await _expectNoArtifacts(supportDirectory, _accountA, type);
  });

  test('失败的前序操作不会阻塞后续同目标删除', () async {
    final target = await _targetFile(
      supportDirectory,
      _accountA,
      PersonalDataType.erke,
    );
    await target.parent.create(recursive: true);
    await File('${target.path}.1-2.bak').writeAsBytes(<int>[1], flush: true);
    await File('${target.path}.3-4.bak').writeAsBytes(<int>[2], flush: true);

    final failedRead = backend.read(
      accountHash: _accountA,
      type: PersonalDataType.erke,
    );
    final delete = backend.deleteType(
      accountHash: _accountA,
      type: PersonalDataType.erke,
    );

    await expectLater(
      failedRead,
      throwsA(isA<PersonalSnapshotStoreException>()),
    );
    await delete;
    expect(await target.exists(), isFalse);
    await _expectNoArtifacts(
      supportDirectory,
      _accountA,
      PersonalDataType.erke,
    );
  });

  test('不同数据类型不因单个目标写入暂停而互相阻塞', () async {
    final backupMoved = Completer<void>();
    final allowWriteToContinue = Completer<void>();
    final writer = IoPersonalSnapshotFileBackend(
      supportDirectoryLoader: () async => supportDirectory,
      onBackupMoved: () async {
        backupMoved.complete();
        await allowWriteToContinue.future;
      },
    );
    final otherTypeWriter = IoPersonalSnapshotFileBackend(
      supportDirectoryLoader: () async => supportDirectory,
    );

    await writer.write(
      accountHash: _accountA,
      type: PersonalDataType.erke,
      bytes: Uint8List.fromList(<int>[1]),
    );
    final blockedWrite = writer.write(
      accountHash: _accountA,
      type: PersonalDataType.erke,
      bytes: Uint8List.fromList(<int>[2]),
    );
    await backupMoved.future;

    await otherTypeWriter
        .write(
          accountHash: _accountA,
          type: PersonalDataType.physical,
          bytes: Uint8List.fromList(<int>[3]),
        )
        .timeout(const Duration(seconds: 1));

    allowWriteToContinue.complete();
    await blockedWrite;
    expect(
      await otherTypeWriter.read(
        accountHash: _accountA,
        type: PersonalDataType.physical,
      ),
      Uint8List.fromList(<int>[3]),
    );
  });

  test('删除账号会等待该账号的活跃写入完成', () async {
    final backupMoved = Completer<void>();
    final allowWriteToContinue = Completer<void>();
    final writer = IoPersonalSnapshotFileBackend(
      supportDirectoryLoader: () async => supportDirectory,
      onBackupMoved: () async {
        backupMoved.complete();
        await allowWriteToContinue.future;
      },
    );
    final deleter = IoPersonalSnapshotFileBackend(
      supportDirectoryLoader: () async => supportDirectory,
    );

    await writer.write(
      accountHash: _accountA,
      type: PersonalDataType.erke,
      bytes: Uint8List.fromList(<int>[1]),
    );
    final write = writer.write(
      accountHash: _accountA,
      type: PersonalDataType.erke,
      bytes: Uint8List.fromList(<int>[2]),
    );
    await backupMoved.future;

    var deleteCompleted = false;
    final delete = deleter.deleteUser(_accountA).then((_) {
      deleteCompleted = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(deleteCompleted, isFalse);

    allowWriteToContinue.complete();
    await write;
    await delete;
    final accountDirectory = Directory(
      path.join(supportDirectory.path, 'personal_vault', _accountA),
    );
    expect(await accountDirectory.exists(), isFalse);
  });

  test('全量删除会等待所有已开始的保险箱写入完成', () async {
    final backupMoved = Completer<void>();
    final allowWriteToContinue = Completer<void>();
    final writer = IoPersonalSnapshotFileBackend(
      supportDirectoryLoader: () async => supportDirectory,
      onBackupMoved: () async {
        backupMoved.complete();
        await allowWriteToContinue.future;
      },
    );
    final deleter = IoPersonalSnapshotFileBackend(
      supportDirectoryLoader: () async => supportDirectory,
    );

    await writer.write(
      accountHash: _accountA,
      type: PersonalDataType.physical,
      bytes: Uint8List.fromList(<int>[1]),
    );
    final write = writer.write(
      accountHash: _accountA,
      type: PersonalDataType.physical,
      bytes: Uint8List.fromList(<int>[2]),
    );
    await backupMoved.future;

    var deleteCompleted = false;
    final delete = deleter.deleteAll().then((_) {
      deleteCompleted = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(deleteCompleted, isFalse);

    allowWriteToContinue.complete();
    await write;
    await delete;
    final vaultRoot = Directory(
      path.join(supportDirectory.path, 'personal_vault'),
    );
    expect(await vaultRoot.exists(), isFalse);
  });
}

Future<File> _targetFile(
  Directory supportDirectory,
  String accountHash,
  PersonalDataType type,
) async {
  final directory = Directory(
    path.join(supportDirectory.path, 'personal_vault', accountHash),
  );
  return File(path.join(directory.path, '${type.storageValue}.bin'));
}

Future<void> _expectNoArtifacts(
  Directory supportDirectory,
  String accountHash,
  PersonalDataType type,
) async {
  final target = await _targetFile(supportDirectory, accountHash, type);
  final artifacts = await target.parent
      .list(followLinks: false)
      .where((entity) => entity.path.startsWith('${target.path}.'))
      .toList();
  expect(artifacts, isEmpty);
}

const String _accountA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _accountB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
