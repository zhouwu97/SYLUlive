/// 消息和 Recent 使用的轻量资源引用。
///
/// `fileId` 保持 int，与现有 Message.FileID/File 模型一致；删除收藏或
/// Pack 时不能把它当成资源目录中的本地路径处理。
class EmojiAssetRef {
  const EmojiAssetRef({
    required this.assetKey,
    this.packId,
    this.fileId,
    this.contentHash,
    this.width,
    this.height,
    this.mimeType,
  });

  final String assetKey;
  final String? packId;
  final int? fileId;
  final String? contentHash;
  final int? width;
  final int? height;
  final String? mimeType;
}
