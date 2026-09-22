import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:shenliyuan/features/emoji/application/emoji_pack_importer.dart';
import 'package:shenliyuan/features/emoji/application/emoji_pack_installer.dart';
import 'package:shenliyuan/features/emoji/data/emoji_pack_local_store.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_feature_flags.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack.dart';

void main() {
  late Directory root;
  late EmojiPackLocalStore store;
  final png = image.encodePng(image.Image(width: 2, height: 2));
  Future<File> archive(
      {String path = 'assets/a.png',
      String fileName = 'input.sylupack',
      String? hash,
      String mime = 'image/png',
      int schema = 1,
      bool symlink = false,
      bool extra = false,
      int? width}) async {
    final manifest = {
      'schema_version': schema,
      'pack_id': 'official-pack',
      'official': true,
      'version': 1,
      'total_size': png.length,
      'assets': [
        {
          'id': 'a',
          'name': 'a',
          'path': path,
          'mime_type': mime,
          'file_size': png.length,
          'sha256': hash ?? sha256.convert(png).toString(),
          if (width != null) 'width': width
        }
      ]
    };
    final asset = ArchiveFile.bytes(path, png);
    if (symlink) {
      asset.mode = 0xa1ff;
      asset.symbolicLink = '../../outside';
    }
    final archive = Archive()
      ..add(ArchiveFile.string('manifest.json', jsonEncode(manifest)))
      ..add(asset);
    if (extra) archive.add(ArchiveFile.string('extra.txt', 'unexpected'));
    final file = File('${root.path}/$fileName');
    await file.writeAsBytes(ZipEncoder().encode(archive));
    return file;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('emoji-import-');
    store = EmojiPackLocalStore(Directory('${root.path}/store'));
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  EmojiPackImporter importer({bool enabled = true}) =>
      EmojiPackImporter(EmojiPackInstaller(store),
          flags: EmojiFeatureFlags(customPackImport: enabled));

  test('默认 Flag 阻断动作，合法包离线安装且无法自称官方', () async {
    final file = await archive();
    await expectLater(
        importer(enabled: false).importFile(file), throwsStateError);
    expect(await store.load(), isEmpty);
    final installed = await importer().importFile(file);
    expect(installed.trustLevel, EmojiPackTrustLevel.localUntrusted);
    expect(installed.packId, startsWith('local-'));
    expect(await store.load(), hasLength(1));
  });

  test('本地包身份随机，相同外部 pack_id 的不同文件互不顶替', () async {
    final first = await archive();
    final second =
        await archive(path: 'assets/b.png', fileName: 'second.sylupack');
    final imported = await importer().importFile(first);
    final legacyId =
        'local-${sha256.convert(utf8.encode('official-pack')).toString()}';
    expect(imported.packId, isNot(legacyId));
    expect(imported.externalPackId, 'official-pack');
    expect(
        imported.importSourceSha256,
        sha256.convert(await first.readAsBytes()).toString());
    final replaced = await importer().importFile(second);
    expect(replaced.packId, isNot(imported.packId));
    expect(await store.load(), hasLength(2));
  });

  test('重新导入同一个文件沿用原有本地包', () async {
    final file = await archive();
    final first = await importer().importFile(file);
    final again = await importer().importFile(file);
    expect(again.packId, first.packId);
    expect(again.importSourceSha256, first.importSourceSha256);
    // 重复导入同一文件是原地幂等安装，不该凭空造出一个「上一版」。
    expect(again.previous, isNull);
    final persisted = await store.load();
    expect(persisted, hasLength(1));
    expect(persisted.single.externalPackId, 'official-pack');
    await expectLater(
        EmojiPackInstaller(store).rollback(first.packId), throwsStateError);
  });
  for (final path in [
    '../outside.png',
    '/absolute.png',
    'C:/escape.png',
    'assets\\escape.png',
    'assets/../a.png',
    'assets/a.png:stream',
    'CON.png',
    'assets/a.'
  ]) {
    test('拒绝危险路径 $path', () async {
      await expectLater(importer().importFile(await archive(path: path)),
          throwsFormatException);
      expect(await store.load(), isEmpty);
    });
  }
  test('拒绝软链接', () async {
    await expectLater(importer().importFile(await archive(symlink: true)),
        throwsFormatException);
    expect(await store.load(), isEmpty);
  });
  test('拒绝未知 schema、额外文件、Hash、MIME 和尺寸不匹配', () async {
    for (final file in [await archive(schema: 2)]) {
      await expectLater(importer().importFile(file), throwsFormatException);
    }
    await expectLater(importer().importFile(await archive(extra: true)),
        throwsFormatException);
    await expectLater(importer().importFile(await archive(hash: '0' * 64)),
        throwsFormatException);
    await expectLater(importer().importFile(await archive(mime: 'image/jpeg')),
        throwsFormatException);
    await expectLater(importer().importFile(await archive(width: 5000)),
        throwsFormatException);
    expect(await store.load(), isEmpty);
  });
  test('拒绝压缩炸弹和过量文件', () async {
    final bomb = Archive()
      ..add(ArchiveFile.bytes('bomb.bin', List.filled(2 * 1024 * 1024, 0)));
    final file = File('${root.path}/bomb.sylupack');
    await file.writeAsBytes(ZipEncoder().encode(bomb));
    await expectLater(importer().importFile(file), throwsFormatException);
    final many = Archive();
    for (var i = 0; i < 1002; i++) {
      many.add(ArchiveFile.string('$i.txt', ''));
    }
    await file.writeAsBytes(ZipEncoder().encode(many));
    await expectLater(importer().importFile(file), throwsFormatException);
    expect(await store.load(), isEmpty);
  });
}
