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

const String _accountA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _accountB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
