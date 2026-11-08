import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/emoji/data/emoji_pack_local_store.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack_installation.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_pack_manifest.dart';
import 'package:shenliyuan/features/emoji/presentation/emoji_local_thumbnail.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('官方动图的预览、名称和发送文件逐张按内容对应', () async {
    final groups = jsonDecode(
        File('../server/internal/handlers/sticker_assets/catalog.json')
            .readAsStringSync()) as List;
    final group = groups.singleWhere((item) => item['id'] == 'mingfeng-ovo');
    final assets = <EmojiManifestAsset>[];
    for (final item in group['items'] as List) {
      final source =
          File('../server/internal/handlers/sticker_assets/${item['file']}');
      final bytes = await source.readAsBytes();
      assets.add(EmojiManifestAsset(
          id: item['id'],
          path: item['file'],
          name: item['label'],
          sha256: sha256.convert(bytes).toString(),
          mimeType: item['mime_type'],
          fileSize: bytes.length,
          animated: true));
    }
    final manifest = EmojiPackManifest(
        schemaVersion: 1,
        packId: group['id'],
        version: group['version'],
        totalSize: assets.fold(0, (sum, asset) => sum + asset.fileSize),
        assets: assets);
    final pack = EmojiPackInstallation(
        manifest: manifest,
        manifestSha256: 'test',
        name: group['name'],
        trustLevel: EmojiPackTrustLevel.serverOfficial);
    final store = EmojiPackLocalStore(Directory('unused-test-store'));
    expect(assets, hasLength(16));
    for (final asset in assets) {
      final provider = emojiInstalledThumbnail(store, pack, asset);
      expect(provider, isA<AssetImage>(), reason: asset.name);
      final assetPath = (provider as AssetImage).assetName;
      expect(assetPath, 'assets/images/stickers/mingfeng-ovo/${asset.id}.png');
      final bundled = await rootBundle.load(assetPath);
      expect(
          bundled.buffer
              .asUint8List(bundled.offsetInBytes, bundled.lengthInBytes),
          await File(assetPath).readAsBytes());
    }

    final untrusted = EmojiPackInstallation(
        manifest: manifest,
        manifestSha256: 'test',
        name: group['name'],
        trustLevel: EmojiPackTrustLevel.localUntrusted);
    expect(emojiInstalledThumbnail(store, untrusted, assets.first),
        isA<EmojiLocalThumbnail>());
    final modified = EmojiManifestAsset(
        id: assets.first.id,
        path: assets.first.path,
        name: assets.first.name,
        sha256: '0' * 64,
        mimeType: assets.first.mimeType,
        fileSize: assets.first.fileSize);
    expect(emojiInstalledThumbnail(store, pack, modified),
        isA<EmojiLocalThumbnail>());
    expect(
        assets
            .singleWhere(
                (asset) => asset.id == '4093d7cdb944076e0a8e4e06be2e2776')
            .name,
        '撒');
  });
}
