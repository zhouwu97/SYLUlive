import '../adapters/builtin_sticker_adapter.dart';
import '../adapters/favorite_item_adapter.dart';
import '../domain/emoji_asset.dart';
import '../domain/emoji_asset_key.dart';
import '../domain/emoji_pack.dart';
import '../data/emoji_pack_runtime.dart';
import '../../../services/emoji_favorite_service.dart';
import '../../../widgets/emoji/sticker_catalog.dart';

/// 资源解析只负责把 AssetKey 映射为当前可展示资源，不负责收藏、下载或
/// Recent 写入。远端 Pack/私有资源通过 [remoteResolver] 注入，避免把 Dio
/// 和权限逻辑泄漏到 Domain。
abstract interface class EmojiAssetResolver {
  Future<EmojiAsset?> resolve(EmojiAssetKey key);
}

typedef EmojiRemoteAssetResolver = Future<EmojiAsset?> Function(
  EmojiAssetKey key,
);

class DefaultEmojiAssetResolver implements EmojiAssetResolver {
  DefaultEmojiAssetResolver({
    EmojiFavoriteService? favoriteService,
    BuiltinStickerAdapter? builtinAdapter,
    FavoriteItemAdapter? favoriteItemAdapter,
    this.remoteResolver,
  })  : _favoriteService = favoriteService ?? EmojiFavoriteService.instance,
        _builtinAdapter = builtinAdapter ?? BuiltinStickerAdapter(),
        _favoriteItemAdapter = favoriteItemAdapter ?? FavoriteItemAdapter();

  final EmojiFavoriteService _favoriteService;
  final BuiltinStickerAdapter _builtinAdapter;
  final FavoriteItemAdapter _favoriteItemAdapter;
  final EmojiRemoteAssetResolver? remoteResolver;

  @override
  Future<EmojiAsset?> resolve(EmojiAssetKey key) async {
    switch (key.namespace) {
      case 'unicode':
        return EmojiAsset(
          key: key,
          kind: EmojiAssetKind.unicode,
          origin: EmojiAssetOrigin.builtin,
          name: key.assetId,
          unicode: key.assetId,
        );
      case 'builtin':
        final sticker = appStickerById(key.assetId);
        if (sticker == null) return null;
        final asset = _builtinAdapter.adapt(sticker);
        return asset.key == key ? asset : null;
      case 'private':
        final favorites = await _favoriteService.load();
        for (final favorite in favorites) {
          EmojiAsset asset;
          try {
            asset = _favoriteItemAdapter.adapt(favorite);
          } on FormatException {
            // 已下线的内置贴图或损坏收藏不应阻断其它资源解析。
            continue;
          }
          if (asset.key == key) return asset;
        }
        return remoteResolver?.call(key);
      case 'official':
      case 'local':
        if (remoteResolver != null) return remoteResolver!(key);
        final account = _favoriteService.userId;
        final store = await EmojiPackRuntime.forAccount(account);
        final packs = await store.load();
        if (account != _favoriteService.userId) return null;
        for (final pack
            in packs.where((p) => p.enabled && p.packId == key.packId)) {
          final official =
              pack.trustLevel == EmojiPackTrustLevel.serverOfficial;
          if (official != (key.namespace == 'official')) continue;
          for (final asset in pack.manifest.assets) {
            if (asset.id != key.assetId) continue;
            return EmojiAsset(
                key: key,
                kind: EmojiAssetKind.image,
                origin: official
                    ? EmojiAssetOrigin.officialRemote
                    : EmojiAssetOrigin.importedLocal,
                name: asset.name,
                packId: pack.packId,
                keywords: asset.keywords,
                media: EmojiMediaMetadata(
                    contentHash: asset.sha256,
                    mimeType: asset.mimeType,
                    width: asset.width,
                    height: asset.height,
                    fileSize: asset.fileSize,
                    animated: asset.animated));
          }
        }
        return null;
    }
    return null;
  }

  Future<EmojiAsset?> resolveSerialized(String serialized) async {
    final key = EmojiAssetKey.tryParse(serialized);
    return key == null ? null : resolve(key);
  }
}
