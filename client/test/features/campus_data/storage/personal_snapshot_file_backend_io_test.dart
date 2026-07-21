import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_file_backend_io.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';

void main() {
  late Directory temporary;
  late IoPersonalSnapshotFileBackend backend;
  const account =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('personal-vault-test-');
    backend = IoPersonalSnapshotFileBackend(
      supportDirectoryLoader: () async => temporary,
    );
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('target 缺失且只有合法 backup 时恢复', () async {
    final target = _target(temporary, account, PersonalDataType.academic);
    await target.parent.create(recursive: true);
    final backup = File('${target.path}.123-456.bak');
    await backup.writeAsBytes(<int>[1, 2, 3]);

    final result = await backend.read(
      accountHash: account,
      type: PersonalDataType.academic,
    );

    expect(result, Uint8List.fromList(<int>[1, 2, 3]));
    expect(await target.exists(), isTrue);
    expect(await backup.exists(), isFalse);
  });

  test('target 存在时不被 backup 覆盖并清理遗留文件', () async {
    final target = _target(temporary, account, PersonalDataType.schedule);
    await target.parent.create(recursive: true);
    await target.writeAsBytes(<int>[9]);
    final backup = File('${target.path}.123-456.bak');
    await backup.writeAsBytes(<int>[1]);

    final result = await backend.read(
      accountHash: account,
      type: PersonalDataType.schedule,
    );

    expect(result, Uint8List.fromList(<int>[9]));
    expect(await backup.exists(), isFalse);
  });

  test('多个 backup 时失败关闭', () async {
    final target = _target(temporary, account, PersonalDataType.erke);
    await target.parent.create(recursive: true);
    await File('${target.path}.1-1.bak').writeAsBytes(<int>[1]);
    await File('${target.path}.2-2.bak').writeAsBytes(<int>[2]);

    expect(
      () => backend.read(accountHash: account, type: PersonalDataType.erke),
      throwsA(isA<PersonalSnapshotStoreException>()),
    );
  });

  test('临时文件不会被当作正式快照恢复', () async {
    final target = _target(temporary, account, PersonalDataType.physical);
    await target.parent.create(recursive: true);
    final temporaryFile = File('${target.path}.123-456.tmp');
    await temporaryFile.writeAsBytes(<int>[1]);

    final result = await backend.read(
      accountHash: account,
      type: PersonalDataType.physical,
    );

    expect(result, isNull);
    expect(await temporaryFile.exists(), isFalse);
  });
}

File _target(
  Directory support,
  String account,
  PersonalDataType type,
) =>
    File(
      path.join(
        support.path,
        'personal_vault',
        account,
        '${type.storageValue}.bin',
      ),
    );
