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

// 客户端仅内置首组贴图，其余官方表情包由服务器目录提供。
const List<AppStickerGroup> appStickerGroups = [
  AppStickerGroup(id: 'mingfeng-daily', name: '明风·日常', items: [
    AppSticker(id: 'aad70d8d064f9eb79286c1393490716c', label: '亲亲', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/aad70d8d064f9eb79286c1393490716c.png'),
    AppSticker(id: 'd0deb840abc781f414c7ad6824407964', label: '粘', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/d0deb840abc781f414c7ad6824407964.png'),
    AppSticker(id: '1c704494bbb89fce27681425cffbe6fa', label: '认真', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/1c704494bbb89fce27681425cffbe6fa.png'),
    AppSticker(id: '36286e5249dbbd659981ca530e21c047', label: '抱', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/36286e5249dbbd659981ca530e21c047.png'),
    AppSticker(id: '0eeed98ece4e89243db9dea7ccd796fd', label: '敢这么说话', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/0eeed98ece4e89243db9dea7ccd796fd.png'),
    AppSticker(id: '4535efdfbdc938e7c225528e8915285b', label: '花花', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/4535efdfbdc938e7c225528e8915285b.png'),
    AppSticker(id: 'd0ccdc6d8c3e941529e797b4d8d5ef85', label: '看手机', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/d0ccdc6d8c3e941529e797b4d8d5ef85.png'),
    AppSticker(id: '5d9aa5f7f3b304bf7cffa81cdde8901c', label: '长条', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/5d9aa5f7f3b304bf7cffa81cdde8901c.png'),
    AppSticker(id: '6d65948c4146fc8a669b9bb10f3832e6', label: '捏', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/6d65948c4146fc8a669b9bb10f3832e6.png'),
    AppSticker(id: 'd931ab4696e4003b744092c1acd3b6c8', label: '拍照', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/d931ab4696e4003b744092c1acd3b6c8.png'),
    AppSticker(id: '2d094a6c0e1ac32d31a65286eb141a57', label: '阿巴', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/2d094a6c0e1ac32d31a65286eb141a57.png'),
    AppSticker(id: 'bf4fdc61f3162854bd1e8f80114f0624', label: '猫', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/bf4fdc61f3162854bd1e8f80114f0624.png'),
    AppSticker(id: '6608d1dacfcde27f87f7d3852330d0fb', label: '叹气', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/6608d1dacfcde27f87f7d3852330d0fb.png'),
    AppSticker(id: '986e5bd2a4b13d23b32416c046ecb068', label: '苦露西', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/986e5bd2a4b13d23b32416c046ecb068.png'),
    AppSticker(id: 'f824b5b93951ea809e59bab466114f71', label: '辛苦了', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/f824b5b93951ea809e59bab466114f71.png'),
    AppSticker(id: 'f05144bf668463d3f2742765d6f8da14', label: '疑惑', thumbnailAsset: 'assets/images/stickers/mingfeng-daily/f05144bf668463d3f2742765d6f8da14.png'),
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
