import 'emoji_asset_key.dart';

/// 当前账号与资源的关系，不把收藏状态塞进 EmojiAsset。
class EmojiUserAssetState {
  const EmojiUserAssetState({
    required this.assetKey,
    this.isFavorite = false,
    this.favoriteSortOrder,
  });

  final EmojiAssetKey assetKey;
  final bool isFavorite;
  final int? favoriteSortOrder;
}
