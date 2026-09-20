import 'package:crypto/crypto.dart';
import 'dart:convert';

import '../../../services/emoji_favorite_service.dart';
import '../../../widgets/emoji/sticker_catalog.dart';
import 'builtin_sticker_adapter.dart';
import '../domain/emoji_asset.dart';
import '../domain/emoji_asset_key.dart';

/// 将旧收藏模型转换为 Asset；收藏关系本身仍由 EmojiFavoriteService 管理。
class FavoriteItemAdapter {
  FavoriteItemAdapter({BuiltinStickerAdapter? builtinAdapter})
      : _builtinAdapter = builtinAdapter ?? BuiltinStickerAdapter();

  final BuiltinStickerAdapter _builtinAdapter;

  EmojiAsset adapt(EmojiFavoriteItem item) {
    if (item.type == EmojiFavoriteType.sticker) {
      final stickerId = item.stickerId?.trim();
      if (stickerId == null || stickerId.isEmpty) {
        throw const FormatException('收藏贴图缺少 stickerId');
      }
      final sticker = appStickerById(stickerId);
      if (sticker == null) {
        throw FormatException('找不到内置贴图: $stickerId');
      }
      return _builtinAdapter.adapt(sticker);
    }

    final assetId = item.assetId ?? item.serverId;
    final id = assetId != null
        ? assetId.toString()
        : item.fileId != null
            ? 'file-${item.fileId}'
            : _urlIdentity(item.imageUrl ?? item.thumbnailUrl);
    if (id.isEmpty) throw const FormatException('收藏图片缺少资源身份');
    return EmojiAsset(
      key: EmojiAssetKey(namespace: 'private', assetId: id),
      kind: EmojiAssetKind.image,
      origin: EmojiAssetOrigin.userPrivate,
      name: item.isAnimated ? '收藏图片（GIF 动图）' : '收藏图片',
      media: EmojiMediaMetadata(
        fileId: item.fileId,
        mimeType: item.mimeType,
        animated: item.isAnimated,
        fileSize: item.compressedSize,
        remoteUrl: item.imageUrl,
        thumbnailUrl: item.thumbnailUrl,
      ),
    );
  }

  EmojiAsset toAsset(EmojiFavoriteItem item) => adapt(item);

  EmojiAsset fromFavorite(EmojiFavoriteItem item) => adapt(item);

  String _urlIdentity(String? value) {
    final normalized = value?.trim() ?? '';
    if (normalized.isEmpty) return '';
    return 'url-${sha256.convert(utf8.encode(normalized))}';
  }
}
