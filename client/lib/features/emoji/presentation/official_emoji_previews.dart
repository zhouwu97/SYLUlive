import '../domain/emoji_pack.dart';
import '../domain/emoji_pack_installation.dart';
import '../domain/emoji_pack_manifest.dart';

// 源贴图的静态封面与发送 GIF 以内容哈希绑定；改版或第三方同 ID 不复用。
const _officialGIFHashes = <String, String>{
  '6370dbf8a240aa98d5b71582dc70a211':
      '0c675dc2130fc4c64fa4baa693cba3756a256ee7b3acd12baad2c0f3af29dcc1',
  '3a23a1641d24e756461e575efc34efe9':
      'edc710cccc391dc41e10af74c9f41c3cfc99e87c4c781435df9df5c9002bc529',
  'c1b8473a302b379591b8bef7c0c2f9cd':
      'e5b15808a26ee372a0a3f8d1a064d64b12c3d437b9358fcb45dfdde9de7b047e',
  'c9ad6e9fa2baf83ce2073249c77d85c0':
      '4da91c88023ea6f36fde148116377e65aff8fbcd6f4135f8564b584d2af96c39',
  '5726c9c935a255106d90e46857441a0c':
      '9d71bd562e70347c8b18d15b73849342a905c8f20c4371c438bcf3500beb8ea0',
  '4093d7cdb944076e0a8e4e06be2e2776':
      '7b9c938279d0f9ddc716cf6e458dfe2ccf92aead43a1277f842db6dc2502794a',
  '63f9cb8a346d8cc21cb006b48b93e07e':
      'fa9562a9577c93aab96963bd322984e67b8c084211ad85e8ad49708766771b6f',
  'd38554d91745da379f208122f2a153c1':
      '41f30487a84e9d1ac9e604b8bfcc234ace4ea39bdee9252050c32f54d0070b41',
  '12fdec70b5d7d5dc0497b175594bab65':
      '9cf8cd6bf82afd1522a7e2732870e6162c49f842ffec4f4bb71b0e8671a5c2ef',
  'dd3904929e09c479945e9b00d7090fdd':
      'f465516acdaa7e05359cfb05ded8e4b3fba5071f564dea05bf575ba8692e701b',
  'b0f41bb02a1554d51ea4382e69725041':
      '9d2013844df67cb2fe70d5d5a09356ab022772aa3a955428a5ee3a842697ac5a',
  'ea32e204f9e4997bfcefaff6847debcb':
      '18231c95c4ba68b85d066e22084eb914eebd42369d5a4afa9e3c9b0a558d8f11',
  'a651cf5813ba41587b22d273682e01ae':
      '44c66e47860a6def2bf589192503ead131d647e253d5c2a055f6a63fc5fe5e8e',
  '0cc4a3688e7b222b977fef3a078619b6':
      '06889f31d129139a90789f256d2d887c7eef970a6d80592b111155f0b03bcc3f',
  '8985274fa30525fddf1221fd4d3aef90':
      '524ecfbf12377e08952866c51eac397b1f7ebd25ec6da81fab37e9f116ae48e4',
  '4295842cc56caa7d48e4a12d81ea02e0':
      '42f0856b249e8752bbf13a6474ced4a3835641c17f60b34696312d817322fc91',
};

String? officialEmojiPreview(
    EmojiPackInstallation pack, EmojiManifestAsset asset) {
  if (pack.trustLevel != EmojiPackTrustLevel.serverOfficial ||
      pack.packId != 'mingfeng-ovo') {
    return null;
  }
  return officialEmojiPreviewForAsset(pack.packId, asset);
}

String? officialEmojiPreviewForAsset(String packId, EmojiManifestAsset asset) {
  if (packId != 'mingfeng-ovo' ||
      asset.mimeType.toLowerCase() != 'image/gif' ||
      _officialGIFHashes[asset.id] != asset.sha256.toLowerCase()) {
    return null;
  }
  return 'assets/images/stickers/mingfeng-ovo/${asset.id}.png';
}
