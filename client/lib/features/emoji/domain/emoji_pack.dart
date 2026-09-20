import 'emoji_asset_key.dart';

enum EmojiPackSource {
  builtin,
  officialRemote,
  privateRemote,
  importedLocal,
}

enum EmojiPackVisibility { privatePack, unlisted, publicPack }

enum EmojiPackTrustLevel {
  bundledOfficial,
  serverOfficial,
  privateOwned,
  localUntrusted,
}

/// Pack 的目录元数据，不包含本机安装状态。
class EmojiPack {
  const EmojiPack({
    required this.id,
    required this.name,
    required this.source,
    required this.trustLevel,
    required this.latestVersion,
    required this.assetCount,
    required this.totalSize,
    this.description,
    this.coverAssetKey,
    this.versionName,
    this.updatedAt,
    this.visibility = EmojiPackVisibility.privatePack,
  });

  final String id;
  final String name;
  final String? description;
  final String? coverAssetKey;
  final EmojiPackSource source;
  final EmojiPackTrustLevel trustLevel;
  final EmojiPackVisibility visibility;
  final int latestVersion;
  final String? versionName;
  final int assetCount;
  final int totalSize;
  final DateTime? updatedAt;

  EmojiAssetKey? get coverKey => EmojiAssetKey.tryParse(coverAssetKey);
}
