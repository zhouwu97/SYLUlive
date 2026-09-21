import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/emoji/adapters/builtin_sticker_adapter.dart';
import 'package:shenliyuan/features/emoji/adapters/favorite_item_adapter.dart';
import 'package:shenliyuan/features/emoji/application/emoji_asset_resolver.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_asset.dart';
import 'package:shenliyuan/features/emoji/domain/emoji_asset_key.dart';
import 'package:shenliyuan/services/emoji_favorite_service.dart';
import 'package:shenliyuan/widgets/emoji/sticker_catalog.dart';

void main() {
  test('converts a generated builtin sticker without changing its catalog id',
      () {
    final sticker = appStickerGroups.first.items.first;
    final asset = BuiltinStickerAdapter().adapt(sticker);

    expect(asset.key.serialized, 'builtin:mingfeng-daily:${sticker.id}');
    expect(asset.origin, EmojiAssetOrigin.builtin);
  });

  test('converts legacy custom favorite to a private asset', () {
    const favorite = EmojiFavoriteItem.custom(
      assetId: 58291,
      fileId: 17,
      mimeType: 'image/png',
    );
    final asset = FavoriteItemAdapter().adapt(favorite);

    expect(
        asset.key, const EmojiAssetKey(namespace: 'private', assetId: '58291'));
    expect(asset.media?.fileId, 17);
    expect(asset.origin, EmojiAssetOrigin.userPrivate);
  });

  test('resolves unicode and builtin assets while delegating remote origins',
      () async {
    final resolver = DefaultEmojiAssetResolver(
      favoriteService: EmojiFavoriteService(
        preferencesLoader: () async => throw StateError('not needed'),
      ),
      remoteResolver: (key) async => EmojiAsset(
        key: key,
        kind: EmojiAssetKind.image,
        origin: EmojiAssetOrigin.officialRemote,
        name: key.assetId,
      ),
    );

    final unicode = await resolver.resolveSerialized('unicode:😀');
    expect(unicode?.kind, EmojiAssetKind.unicode);
    expect(unicode?.unicode, '😀');

    final builtin = await resolver.resolve(
      EmojiAssetKey(
        namespace: 'builtin',
        packId: 'mingfeng-daily',
        assetId: appStickerGroups.first.items.first.id,
      ),
    );
    expect(builtin?.origin, EmojiAssetOrigin.builtin);

    final official = await resolver.resolve(
      const EmojiAssetKey(
        namespace: 'official',
        packId: 'official-pack',
        assetId: 'asset-1',
      ),
    );
    expect(official?.origin, EmojiAssetOrigin.officialRemote);
  });
}
