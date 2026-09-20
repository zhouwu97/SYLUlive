import 'emoji_asset_key.dart';

/// 设备侧状态，与资源描述和用户收藏关系分开保存。
class EmojiAssetLocalState {
  const EmojiAssetLocalState({
    required this.assetKey,
    this.localPath,
    this.contentHash,
    this.available = true,
  });

  final EmojiAssetKey assetKey;
  final String? localPath;
  final String? contentHash;
  final bool available;
}
