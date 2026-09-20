import 'emoji_asset_key.dart';

enum EmojiAssetKind { unicode, image }

enum EmojiAssetOrigin {
  builtin,
  officialRemote,
  userPrivate,
  importedLocal,
}

/// 媒体实体的可选元数据。未知字段保持 null，不从缩略图或默认值猜测。
class EmojiMediaMetadata {
  const EmojiMediaMetadata({
    this.fileId,
    this.contentHash,
    this.mimeType,
    this.width,
    this.height,
    this.fileSize,
    this.animated,
    this.remoteUrl,
    this.thumbnailUrl,
  });

  final int? fileId;
  final String? contentHash;
  final String? mimeType;
  final int? width;
  final int? height;
  final int? fileSize;
  final bool? animated;

  /// URL 属于解析结果，不参与资源身份计算。
  final String? remoteUrl;
  final String? thumbnailUrl;
}

/// 不包含收藏、Recent 或安装状态的纯资源描述。
class EmojiAsset {
  const EmojiAsset({
    required this.key,
    required this.kind,
    required this.origin,
    required this.name,
    this.packId,
    this.keywords = const <String>[],
    this.pinyin,
    this.initials,
    this.unicode,
    this.media,
  });

  final EmojiAssetKey key;
  final EmojiAssetKind kind;
  final EmojiAssetOrigin origin;
  final String? packId;
  final String name;
  final List<String> keywords;
  final String? pinyin;
  final String? initials;
  final String? unicode;
  final EmojiMediaMetadata? media;

  @override
  bool operator ==(Object other) =>
      other is EmojiAsset && other.key == key && other.kind == kind;

  @override
  int get hashCode => Object.hash(key, kind);
}
