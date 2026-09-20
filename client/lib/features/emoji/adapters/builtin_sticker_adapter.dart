import '../../../widgets/emoji/sticker_catalog.dart';
import '../domain/emoji_asset.dart';
import '../domain/emoji_asset_key.dart';

/// 将 APK 内置贴图转换为统一 Asset，不改变 sticker_catalog 的生成结构。
class BuiltinStickerAdapter {
  BuiltinStickerAdapter({this.defaultPackId});

  final String? defaultPackId;

  EmojiAsset adapt(AppSticker sticker, {String? packId}) {
    final resolvedPackId = packId?.trim().isNotEmpty == true
        ? packId!.trim()
        : defaultPackId ?? _packIdFromAssetPath(sticker.thumbnailAsset);
    if (resolvedPackId == null || resolvedPackId.isEmpty) {
      throw const FormatException('内置贴图缺少 packId');
    }
    return EmojiAsset(
      key: EmojiAssetKey(
        namespace: 'builtin',
        packId: resolvedPackId,
        assetId: sticker.id,
      ),
      kind: EmojiAssetKind.image,
      origin: EmojiAssetOrigin.builtin,
      packId: resolvedPackId,
      name: sticker.label,
      media: const EmojiMediaMetadata(
        mimeType: 'image/png',
      ),
    );
  }

  EmojiAsset toAsset(AppSticker sticker, {String? packId}) =>
      adapt(sticker, packId: packId);

  EmojiAsset fromSticker(AppSticker sticker, {String? packId}) =>
      adapt(sticker, packId: packId);

  static String? _packIdFromAssetPath(String path) {
    const marker = 'assets/images/stickers/';
    final start = path.indexOf(marker);
    if (start < 0) return null;
    final rest = path.substring(start + marker.length);
    final slash = rest.indexOf('/');
    if (slash <= 0) return null;
    return rest.substring(0, slash);
  }
}
