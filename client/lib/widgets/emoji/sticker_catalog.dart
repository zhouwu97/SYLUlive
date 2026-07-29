// 本文件由 scripts/import_stickers.ps1 生成，请勿手工维护。
class AppSticker {
  final String id;
  final String label;
  final String thumbnailAsset;

  const AppSticker({required this.id, required this.label, required this.thumbnailAsset});
}

class AppStickerGroup {
  final String id;
  final String name;
  final List<AppSticker> items;

  const AppStickerGroup({required this.id, required this.name, required this.items});
}

const List<AppStickerGroup> appStickerGroups = [
  AppStickerGroup(id: 'mingfeng-daily', name: '明风·日常', items: [
    AppSticker(id: '0eeed98ece4e89243db9dea7ccd796fd', label: '表情 1', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/0eeed98ece4e89243db9dea7ccd796fd.png'),
    AppSticker(id: '1c704494bbb89fce27681425cffbe6fa', label: '表情 2', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/1c704494bbb89fce27681425cffbe6fa.png'),
    AppSticker(id: '2d094a6c0e1ac32d31a65286eb141a57', label: '表情 3', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/2d094a6c0e1ac32d31a65286eb141a57.png'),
    AppSticker(id: '36286e5249dbbd659981ca530e21c047', label: '表情 4', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/36286e5249dbbd659981ca530e21c047.png'),
    AppSticker(id: '4535efdfbdc938e7c225528e8915285b', label: '表情 5', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/4535efdfbdc938e7c225528e8915285b.png'),
    AppSticker(id: '5d9aa5f7f3b304bf7cffa81cdde8901c', label: '表情 6', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/5d9aa5f7f3b304bf7cffa81cdde8901c.png'),
    AppSticker(id: '6608d1dacfcde27f87f7d3852330d0fb', label: '表情 7', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/6608d1dacfcde27f87f7d3852330d0fb.png'),
    AppSticker(id: '6d65948c4146fc8a669b9bb10f3832e6', label: '表情 8', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/6d65948c4146fc8a669b9bb10f3832e6.png'),
    AppSticker(id: '986e5bd2a4b13d23b32416c046ecb068', label: '表情 9', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/986e5bd2a4b13d23b32416c046ecb068.png'),
    AppSticker(id: 'aad70d8d064f9eb79286c1393490716c', label: '表情 10', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/aad70d8d064f9eb79286c1393490716c.png'),
    AppSticker(id: 'bf4fdc61f3162854bd1e8f80114f0624', label: '表情 11', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/bf4fdc61f3162854bd1e8f80114f0624.png'),
    AppSticker(id: 'd0ccdc6d8c3e941529e797b4d8d5ef85', label: '表情 12', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/d0ccdc6d8c3e941529e797b4d8d5ef85.png'),
    AppSticker(id: 'd0deb840abc781f414c7ad6824407964', label: '表情 13', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/d0deb840abc781f414c7ad6824407964.png'),
    AppSticker(id: 'd931ab4696e4003b744092c1acd3b6c8', label: '表情 14', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/d931ab4696e4003b744092c1acd3b6c8.png'),
    AppSticker(id: 'f05144bf668463d3f2742765d6f8da14', label: '表情 15', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/f05144bf668463d3f2742765d6f8da14.png'),
    AppSticker(id: 'f824b5b93951ea809e59bab466114f71', label: '表情 16', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/f824b5b93951ea809e59bab466114f71.png'),
  ]),
  AppStickerGroup(id: 'mingfeng-ovo', name: '明风 OvO', items: [
    AppSticker(id: '6370dbf8a240aa98d5b71582dc70a211', label: '不可以', thumbnailAsset: 'assets/images/stickers/mingfeng-ovo/6370dbf8a240aa98d5b71582dc70a211.png'),
    AppSticker(id: '3a23a1641d24e756461e575efc34efe9', label: '红包', thumbnailAsset: 'assets/images/stickers/mingfeng-ovo/3a23a1641d24e756461e575efc34efe9.png'),
    AppSticker(id: 'c1b8473a302b379591b8bef7c0c2f9cd', label: '喜欢你', thumbnailAsset: 'assets/images/stickers/mingfeng-ovo/c1b8473a302b379591b8bef7c0c2f9cd.png'),
    AppSticker(id: 'c9ad6e9fa2baf83ce2073249c77d85c0', label: '摸鱼', thumbnailAsset: 'assets/images/stickers/mingfeng-ovo/c9ad6e9fa2baf83ce2073249c77d85c0.png'),
    AppSticker(id: '5726c9c935a255106d90e46857441a0c', label: '吸氧', thumbnailAsset: 'assets/images/stickers/mingfeng-ovo/5726c9c935a255106d90e46857441a0c.png'),
    AppSticker(id: '4093d7cdb944076e0a8e4e06be2e2776', label: '撒', thumbnailAsset: 'assets/images/stickers/mingfeng-ovo/4093d7cdb944076e0a8e4e06be2e2776.png'),
    AppSticker(id: '63f9cb8a346d8cc21cb006b48b93e07e', label: '吃饼', thumbnailAsset: 'assets/images/stickers/mingfeng-ovo/63f9cb8a346d8cc21cb006b48b93e07e.png'),
    AppSticker(id: 'd38554d91745da379f208122f2a153c1', label: '喇叭', thumbnailAsset: 'assets/images/stickers/mingfeng-ovo/d38554d91745da379f208122f2a153c1.png'),
    AppSticker(id: '12fdec70b5d7d5dc0497b175594bab65', label: '失落', thumbnailAsset: 'assets/images/stickers/mingfeng-ovo/12fdec70b5d7d5dc0497b175594bab65.png'),
    AppSticker(id: 'dd3904929e09c479945e9b00d7090fdd', label: '画画', thumbnailAsset: 'assets/images/stickers/mingfeng-ovo/dd3904929e09c479945e9b00d7090fdd.png'),
    AppSticker(id: 'b0f41bb02a1554d51ea4382e69725041', label: '冒泡', thumbnailAsset: 'assets/images/stickers/mingfeng-ovo/b0f41bb02a1554d51ea4382e69725041.png'),
    AppSticker(id: 'ea32e204f9e4997bfcefaff6847debcb', label: '局子', thumbnailAsset: 'assets/images/stickers/mingfeng-ovo/ea32e204f9e4997bfcefaff6847debcb.png'),
    AppSticker(id: 'a651cf5813ba41587b22d273682e01ae', label: '含泪掏钱', thumbnailAsset: 'assets/images/stickers/mingfeng-ovo/a651cf5813ba41587b22d273682e01ae.png'),
    AppSticker(id: '0cc4a3688e7b222b977fef3a078619b6', label: '出锅', thumbnailAsset: 'assets/images/stickers/mingfeng-ovo/0cc4a3688e7b222b977fef3a078619b6.png'),
    AppSticker(id: '8985274fa30525fddf1221fd4d3aef90', label: '蛋糕', thumbnailAsset: 'assets/images/stickers/mingfeng-ovo/8985274fa30525fddf1221fd4d3aef90.png'),
    AppSticker(id: '4295842cc56caa7d48e4a12d81ea02e0', label: '情书', thumbnailAsset: 'assets/images/stickers/mingfeng-ovo/4295842cc56caa7d48e4a12d81ea02e0.png'),
  ]),
  AppStickerGroup(id: 'mingfengfeng', name: '明风风', items: [
    AppSticker(id: '63cfb0a51097da75df49cb719922b8e7', label: '涩涩', thumbnailAsset: 'assets/images/stickers/mingfengfeng/63cfb0a51097da75df49cb719922b8e7.png'),
    AppSticker(id: 'e417bb87afe85caded296e8c475be864', label: '比心', thumbnailAsset: 'assets/images/stickers/mingfengfeng/e417bb87afe85caded296e8c475be864.png'),
    AppSticker(id: '69ba783fe381142e90124ee1e0fcdec5', label: '黑化', thumbnailAsset: 'assets/images/stickers/mingfengfeng/69ba783fe381142e90124ee1e0fcdec5.png'),
    AppSticker(id: 'ca153e00bcbf3a5a04e2a1cedf4fc735', label: '喝茶', thumbnailAsset: 'assets/images/stickers/mingfengfeng/ca153e00bcbf3a5a04e2a1cedf4fc735.png'),
    AppSticker(id: '701d6d42f9bdb8df4ab565956e0390f0', label: '做不到', thumbnailAsset: 'assets/images/stickers/mingfengfeng/701d6d42f9bdb8df4ab565956e0390f0.png'),
    AppSticker(id: '5cd76a09685d78d5e803384dc5436fe8', label: '猫猫生的', thumbnailAsset: 'assets/images/stickers/mingfengfeng/5cd76a09685d78d5e803384dc5436fe8.png'),
    AppSticker(id: 'cab495ebb00f701357a34c730c667960', label: '哼', thumbnailAsset: 'assets/images/stickers/mingfengfeng/cab495ebb00f701357a34c730c667960.png'),
    AppSticker(id: '2f875950c473b51c6a7015ee22181f11', label: '紧张', thumbnailAsset: 'assets/images/stickers/mingfengfeng/2f875950c473b51c6a7015ee22181f11.png'),
    AppSticker(id: '57a6e6ddf0ed6ae409103a1c79796cda', label: '星星眼', thumbnailAsset: 'assets/images/stickers/mingfengfeng/57a6e6ddf0ed6ae409103a1c79796cda.png'),
    AppSticker(id: '4ea7d374be1cede6e7b9990dbf1f0c59', label: '盯', thumbnailAsset: 'assets/images/stickers/mingfengfeng/4ea7d374be1cede6e7b9990dbf1f0c59.png'),
    AppSticker(id: '40cd7c2491a76b3c998730df4c4d2d1c', label: '趴', thumbnailAsset: 'assets/images/stickers/mingfengfeng/40cd7c2491a76b3c998730df4c4d2d1c.png'),
    AppSticker(id: 'b2df28aa490c058b9fdfba6f96ae28f5', label: '逃离', thumbnailAsset: 'assets/images/stickers/mingfengfeng/b2df28aa490c058b9fdfba6f96ae28f5.png'),
    AppSticker(id: '404375fdaab3eb43488841beb985c395', label: '杂鱼', thumbnailAsset: 'assets/images/stickers/mingfengfeng/404375fdaab3eb43488841beb985c395.png'),
    AppSticker(id: '66c40b9e958abe8adcc2943b191e832f', label: '呜呜', thumbnailAsset: 'assets/images/stickers/mingfengfeng/66c40b9e958abe8adcc2943b191e832f.png'),
    AppSticker(id: '5db6cd535eda31edc0d1983e785bb8cd', label: '诶嘿', thumbnailAsset: 'assets/images/stickers/mingfengfeng/5db6cd535eda31edc0d1983e785bb8cd.png'),
    AppSticker(id: 'f180ae4e76d1896a615f1095044f5ee8', label: '灵魂出窍', thumbnailAsset: 'assets/images/stickers/mingfengfeng/f180ae4e76d1896a615f1095044f5ee8.png'),
  ]),
  AppStickerGroup(id: 'mingfeng', name: '明风', items: [
    AppSticker(id: '693d57aca10e49cb5baf53b8dbb96c36', label: '探头', thumbnailAsset: 'assets/images/stickers/mingfeng/693d57aca10e49cb5baf53b8dbb96c36.png'),
    AppSticker(id: '1568a70091296e5199816f67fe457acc', label: '早安', thumbnailAsset: 'assets/images/stickers/mingfeng/1568a70091296e5199816f67fe457acc.png'),
    AppSticker(id: '7d9614c4d56db06a13cc85420e03ffba', label: '晚安', thumbnailAsset: 'assets/images/stickers/mingfeng/7d9614c4d56db06a13cc85420e03ffba.png'),
    AppSticker(id: 'cee44a40131c4f95098b36430449c912', label: '我要闹了', thumbnailAsset: 'assets/images/stickers/mingfeng/cee44a40131c4f95098b36430449c912.png'),
    AppSticker(id: '303e1f59ad80c492d2e7c15658b00870', label: '疑惑', thumbnailAsset: 'assets/images/stickers/mingfeng/303e1f59ad80c492d2e7c15658b00870.png'),
    AppSticker(id: 'b62b2648f0d40805331d4c45968e4737', label: 'OK', thumbnailAsset: 'assets/images/stickers/mingfeng/b62b2648f0d40805331d4c45968e4737.png'),
    AppSticker(id: 'b0d61e4aa42714bc2c5e5f7cf9480d98', label: '好耶', thumbnailAsset: 'assets/images/stickers/mingfeng/b0d61e4aa42714bc2c5e5f7cf9480d98.png'),
    AppSticker(id: '0ccd6d087a05757fb478bf0601e8c786', label: '哭哭', thumbnailAsset: 'assets/images/stickers/mingfeng/0ccd6d087a05757fb478bf0601e8c786.png'),
    AppSticker(id: '1c5d27144aae834d352e4f6704750458', label: '晕晕', thumbnailAsset: 'assets/images/stickers/mingfeng/1c5d27144aae834d352e4f6704750458.png'),
    AppSticker(id: '5ad44d700fcd9a0c81cf6834ce4e3575', label: '害羞', thumbnailAsset: 'assets/images/stickers/mingfeng/5ad44d700fcd9a0c81cf6834ce4e3575.png'),
    AppSticker(id: '10529d03ba8b034d0e69680e34d45af5', label: '摸头', thumbnailAsset: 'assets/images/stickers/mingfeng/10529d03ba8b034d0e69680e34d45af5.png'),
    AppSticker(id: 'df6dac55ccfc89a4dfc188f320112318', label: '点赞', thumbnailAsset: 'assets/images/stickers/mingfeng/df6dac55ccfc89a4dfc188f320112318.png'),
    AppSticker(id: '82481e8836d11b0eac41ea5addb0da0c', label: 'NO', thumbnailAsset: 'assets/images/stickers/mingfeng/82481e8836d11b0eac41ea5addb0da0c.png'),
    AppSticker(id: '6159bd58fba8eb5c5254f501c958b658', label: '拜托了', thumbnailAsset: 'assets/images/stickers/mingfeng/6159bd58fba8eb5c5254f501c958b658.png'),
    AppSticker(id: '134dfdfb5fd355fbb504b62f0391174b', label: '锤', thumbnailAsset: 'assets/images/stickers/mingfeng/134dfdfb5fd355fbb504b62f0391174b.png'),
    AppSticker(id: '9f3cfb00a3e638491e5435e5550d5c83', label: '惊讶', thumbnailAsset: 'assets/images/stickers/mingfeng/9f3cfb00a3e638491e5435e5550d5c83.png'),
  ]),
] ;

AppSticker? appStickerById(String? id) {
  final normalized = id?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  for (final group in appStickerGroups) {
    for (final sticker in group.items) {
      if (sticker.id == normalized) return sticker;
    }
  }
  return null;
}
