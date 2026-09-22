import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:shenliyuan/features/emoji/application/emoji_pack_installer.dart';
import 'package:shenliyuan/features/emoji/data/emoji_pack_local_store.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack_installation.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack_manifest.dart';

void main() {
  late Directory root;
  late EmojiPackLocalStore store;
  final bytes =
      Uint8List.fromList(image.encodePng(image.Image(width: 2, height: 2)));
  EmojiPackManifest manifest(int version, {String? hash}) => EmojiPackManifest(
          schemaVersion: 1,
          packId: 'test',
          version: version,
          totalSize: bytes.length,
          assets: [
            EmojiManifestAsset(
                id: 'a',
                path: 'assets/a.png',
                name: '表情',
                sha256: hash ?? sha256.convert(bytes).toString(),
                mimeType: 'image/png',
                fileSize: bytes.length)
          ]);
  Future<EmojiPackInstallation> install(
          EmojiPackInstaller installer, int version) =>
      installer.install(
          manifest: manifest(version),
          name: '测试包',
          trustLevel: EmojiPackTrustLevel.localUntrusted,
          readAsset: (_) async => bytes);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('emoji-installer-');
    store = EmojiPackLocalStore(root);
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('坏 Hash 不污染正式目录，更新失败保留旧版', () async {
    await install(EmojiPackInstaller(store), 1);
    await expectLater(
        EmojiPackInstaller(store).install(
            manifest: manifest(2, hash: '0' * 64),
            name: '坏包',
            trustLevel: EmojiPackTrustLevel.localUntrusted,
            readAsset: (_) async => bytes),
        throwsFormatException);
    expect((await store.load()).single.version, 1);
    expect(await store.versionDirectory('test', 2).exists(), isFalse);
    expect(await store.versionDirectory('test', 1).exists(), isTrue);
  });
  for (final phase in ['beforeRename', 'beforeIndex']) {
    test('$phase 中断可恢复并保留旧安装', () async {
      await install(EmojiPackInstaller(store), 1);
      final installer = EmojiPackInstaller(store, checkpoint: (value) async {
        if (value == phase) throw StateError('模拟中断');
      });
      await expectLater(install(installer, 2), throwsStateError);
      await EmojiPackInstaller(EmojiPackLocalStore(root)).recover();
      expect((await store.load()).single.version, 1);
      expect(await store.versionDirectory('test', 2).exists(), isFalse);
    });
  }
  test('重启恢复磁盘 Journal，不把已改名未提交版本显示为已安装', () async {
    await install(EmojiPackInstaller(store), 1);
    final next = EmojiPackInstallation(
        manifest: manifest(2),
        manifestSha256: EmojiPackInstaller.manifestHash(manifest(2)),
        name: '更新',
        trustLevel: EmojiPackTrustLevel.localUntrusted);
    await store.versionDirectory('test', 2).create(recursive: true);
    await File('${root.path}/install-journal.json')
        .writeAsString(jsonEncode({'installation': next.toJson()}));
    await EmojiPackInstaller(EmojiPackLocalStore(root)).recover();
    expect((await store.load()).single.version, 1);
    expect(await store.versionDirectory('test', 2).exists(), isFalse);
  });
  test('回滚提交中断保留可再次回滚的旧版本', () async {
    await install(EmojiPackInstaller(store), 1);
    await install(EmojiPackInstaller(store), 2);
    final interrupted = EmojiPackInstaller(store, checkpoint: (phase) async {
      if (phase == 'beforeIndex') throw StateError('模拟中断');
    });
    await expectLater(interrupted.rollback('test'), throwsStateError);
    expect((await store.load()).single.version, 2);
    expect(
        await File('${store.versionDirectory('test', 1).path}/assets/a.png')
            .readAsBytes(),
        bytes);
    await EmojiPackInstaller(store).rollback('test');
    expect((await store.load()).single.version, 1);
  });
  test('索引提交后中断按成功恢复，损坏的同版本可修复', () async {
    await install(EmojiPackInstaller(store), 1);
    final file = File('${store.versionDirectory('test', 1).path}/assets/a.png');
    await file.writeAsBytes([0]);
    final installer = EmojiPackInstaller(store, checkpoint: (phase) async {
      if (phase == 'afterIndex') throw StateError('模拟中断');
    });
    await install(installer, 1);
    expect(await file.readAsBytes(), bytes);
    expect(
        (await store.load()).single.status, EmojiPackInstallStatus.installed);
  });
  test('更新和回滚都校验内容，同版本不允许替换', () async {
    final installer = EmojiPackInstaller(store);
    await install(installer, 1);
    await install(installer, 2);
    await install(installer, 1);
    expect((await store.load()).single.version, 1);
    expect(await store.versionDirectory('test', 2).exists(), isTrue);
    await expectLater(
        installer.install(
            manifest: manifest(1, hash: '0' * 64),
            name: '替换',
            trustLevel: EmojiPackTrustLevel.localUntrusted,
            readAsset: (_) async => bytes),
        throwsStateError);
  });

  // ====== A06：回滚跟着安装历史，而不是版本数值 ======

  test('EMO-01 新装版本号更小也能回滚到实际上一版', () async {
    // 官方包版本由内容哈希派生、第三方包自报版本，数值大小不代表发布先后。
    final installer = EmojiPackInstaller(store);
    await install(installer, 9001);
    await install(installer, 1001);

    await installer.rollback('test');

    expect((await store.load()).single.version, 9001);
  });

  test('EMO-01 新装版本号更大时同样回到实际上一版', () async {
    final installer = EmojiPackInstaller(store);
    await install(installer, 1001);
    await install(installer, 9001);

    await installer.rollback('test');

    expect((await store.load()).single.version, 1001);
  });

  test('EMO-03 A→B→A 的回滚指针指向中间那次成功安装的 B', () async {
    final installer = EmojiPackInstaller(store);
    await install(installer, 1);
    await install(installer, 2);
    await install(installer, 1);

    await installer.rollback('test');

    expect((await store.load()).single.version, 2);
  });

  test('失败的安装不进入历史，回滚仍指向更早的可用版本', () async {
    final installer = EmojiPackInstaller(store);
    await install(installer, 1);
    await install(installer, 2);
    await expectLater(
        installer.install(
            manifest: manifest(3, hash: '0' * 64),
            name: '坏包',
            trustLevel: EmojiPackTrustLevel.localUntrusted,
            readAsset: (_) async => bytes),
        throwsFormatException);

    await installer.rollback('test');

    expect((await store.load()).single.version, 1);
  });

  test('EMO-02 上一版资源损坏时回滚失败，当前包保持可用', () async {
    final installer = EmojiPackInstaller(store);
    await install(installer, 1);
    await install(installer, 2);
    await File('${store.versionDirectory('test', 1).path}/assets/a.png')
        .writeAsBytes([0]);

    await expectLater(installer.rollback('test'), throwsStateError);

    final current = (await store.load()).single;
    expect(current.version, 2);
    expect(current.status, EmojiPackInstallStatus.installed);
    expect(
        await File('${store.versionDirectory('test', 2).path}/assets/a.png')
            .readAsBytes(),
        bytes);
  });

  test('老索引没有安装历史时不猜测顺序，当前包保持不变', () async {
    await install(EmojiPackInstaller(store), 1);
    await install(EmojiPackInstaller(store), 2);
    // 模拟升级前写下的索引：还没有 previous 指针，只有版本数值。
    final index = await store.readIndex();
    ((index['packs'] as Map)['test'] as Map).remove('previous');
    await store.writeIndex(index);

    await expectLater(
        EmojiPackInstaller(store).rollback('test'), throwsStateError);

    expect((await store.load()).single.version, 2);
  });

  test('同版本重装与损坏标记都不推进回滚指针', () async {
    final installer = EmojiPackInstaller(store);
    await install(installer, 1);
    await install(installer, 2);
    // 抹掉当前版资源，触发「标记损坏 + 原地重装」这条同版本提交路径。
    await File('${store.versionDirectory('test', 2).path}/assets/a.png')
        .writeAsBytes([0]);
    await install(installer, 2);

    await installer.rollback('test');

    expect((await store.load()).single.version, 1);
  });

  test('清理只保留当前与上一版，回滚后还能再滚回来', () async {
    final installer = EmojiPackInstaller(store);
    await install(installer, 1);
    await install(installer, 2);
    await install(installer, 3);
    expect(await store.versionDirectory('test', 1).exists(), isFalse);
    expect(await store.versionDirectory('test', 2).exists(), isTrue);
    expect(await store.versionDirectory('test', 3).exists(), isTrue);

    await installer.rollback('test');
    expect((await store.load()).single.version, 2);

    await installer.rollback('test');
    expect((await store.load()).single.version, 3);
  });

  test('损坏的当前版不占用回滚指针，继续回退到更早的可恢复版', () async {
    final installer = EmojiPackInstaller(store);
    await install(installer, 1);
    await install(installer, 2);
    // 当前版 v2 被标记损坏后再升级到 v3：回滚目标应跳过损坏的 v2。
    final damaged = (await store.load())
        .single
        .copyWith(status: EmojiPackInstallStatus.damaged);
    await store.exclusive(() => store.commit(damaged));
    await install(installer, 3);

    await installer.rollback('test');

    expect((await store.load()).single.version, 1);
  });
}
