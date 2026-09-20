import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/emoji/data/emoji_pack_local_store.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack_manifest.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack_installation.dart';

void main() {
  test('安装状态重启持久化、版本不可变、删除只影响本地包', () async {
    final root = await Directory.systemTemp.createTemp('emoji-store-');
    addTearDown(() => root.delete(recursive: true));
    final store = EmojiPackLocalStore(root);
    const item = EmojiPackInstallation(
        manifest: EmojiPackManifest(
            schemaVersion: 1,
            packId: 'pack',
            version: 1,
            totalSize: 0,
            assets: []),
        manifestSha256: 'abc',
        name: '测试',
        trustLevel: EmojiPackTrustLevel.localUntrusted);
    await store.exclusive(() => store.commit(item));
    await store.setEnabled('pack', false);
    final loaded = (await EmojiPackLocalStore(root).load()).single;
    expect(loaded.enabled, isFalse);
    expect(loaded.hasUpdate(2), isTrue);
    expect(loaded.hasUpdate(1), isFalse);
    final mutated = EmojiPackInstallation(
        manifest: item.manifest,
        manifestSha256: 'def',
        name: item.name,
        trustLevel: item.trustLevel);
    await expectLater(
        store.exclusive(() => store.commit(mutated)), throwsStateError);
    final unrelated = File('${root.path}/message-file');
    await unrelated.writeAsString('历史消息');
    await store.remove('pack');
    expect(await store.load(), isEmpty);
    expect(await unrelated.readAsString(), '历史消息');
    expect((await store.readIndex())['tombstones'], contains('pack'));
  });
}
