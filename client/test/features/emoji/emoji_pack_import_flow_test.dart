import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:shenliyuan/features/emoji/application/emoji_pack_importer.dart';
import 'package:shenliyuan/features/emoji/application/emoji_pack_installer.dart';
import 'package:shenliyuan/features/emoji/data/emoji_pack_local_store.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack.dart';

void main() {
  late Directory root;
  late EmojiPackLocalStore store;
  late EmojiPackImporter importer;
  late File first, second;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('emoji-import-flow-');
    store = EmojiPackLocalStore(Directory('${root.path}/store'));
    importer = EmojiPackImporter(EmojiPackInstaller(store));
    first = await File('${root.path}/开心.png')
        .writeAsBytes(image.encodePng(image.Image(width: 2, height: 2)));
    final other = image.Image(width: 3, height: 3)
      ..setPixelRgba(0, 0, 255, 0, 0, 255);
    second =
        await File('${root.path}/喜欢.png').writeAsBytes(image.encodePng(other));
  });
  tearDown(() async => root.delete(recursive: true));

  test('相册多选先预览不写盘，去重后确认安装；重新排序也不重复安装', () async {
    final prepared = await importer.prepareImages([first, second, first]);
    expect(prepared.manifest.assets, hasLength(2));
    expect(await store.load(), isEmpty);
    final installed = await importer.installPrepared(prepared, name: '日常反应');
    expect(installed.name, '日常反应');
    expect(installed.trustLevel, EmojiPackTrustLevel.localUntrusted);
    final again = await importer
        .installPrepared(await importer.prepareImages([second, first]));
    expect(again.packId, installed.packId);
    expect(again.previous, isNull);
    expect(await store.load(), hasLength(1));
    await store.setEnabled(installed.packId, false);
    final renamed = await importer.installPrepared(prepared, name: '新的名称');
    expect(renamed.enabled, isTrue);
    expect(renamed.name, '新的名称');
    expect(await store.load(), hasLength(1));
  });

  test('普通 ZIP 自动生成清单并保留 GIF 动图，忽略 macOS 元数据', () async {
    final frameA = image.Image(width: 2, height: 2);
    frameA.addFrame(
        image.Image(width: 2, height: 2)..setPixelRgba(0, 0, 0, 255, 0, 255));
    final gif = image.encodeGif(frameA);
    final archive = Archive()
      ..add(ArchiveFile.bytes('日常/开心.png', await first.readAsBytes()))
      ..add(ArchiveFile.bytes('日常/动画.gif', gif))
      ..add(ArchiveFile.string('__MACOSX/._开心.png', 'metadata'));
    final file = await File('${root.path}/日常.zip')
        .writeAsBytes(ZipEncoder().encode(archive));
    final prepared = await importer.prepareFile(file);
    expect(prepared.name, '日常');
    expect(prepared.manifest.assets, hasLength(2));
    expect(prepared.manifest.assets.last.animated, isTrue);
    final installed = await importer.installPrepared(prepared);
    expect(installed.enabled, isTrue);
  });

  test('账号变化拒绝确认，图片损坏或含其他文件的 ZIP 不产生安装', () async {
    final prepared = await importer.prepareImages([first]);
    await expectLater(
        importer.installPrepared(prepared, isCurrent: () => false),
        throwsStateError);
    final broken =
        await File('${root.path}/坏图.png').writeAsString('not-an-image');
    await expectLater(importer.prepareImages([broken]), throwsFormatException);
    final archive = Archive()
      ..add(ArchiveFile.bytes('a.png', await first.readAsBytes()))
      ..add(ArchiveFile.string('run.exe', 'untrusted'));
    final file = await File('${root.path}/unsafe.zip')
        .writeAsBytes(ZipEncoder().encode(archive));
    await expectLater(importer.prepareFile(file), throwsFormatException);
    expect(await store.load(), isEmpty);
  });
}
