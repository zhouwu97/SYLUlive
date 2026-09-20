import 'emoji_asset_key.dart';

/// 账号范围内的最近使用关系，不改变资源本身的身份或安装状态。
class EmojiRecentRecord {
  const EmojiRecentRecord({
    required this.assetKey,
    required this.lastUsedAt,
    required this.useCount,
    this.packId,
  });

  final String assetKey;
  final String? packId;
  final DateTime lastUsedAt;
  final int useCount;

  EmojiAssetKey get key => EmojiAssetKey.parse(assetKey);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'asset_key': assetKey,
        if (packId != null) 'pack_id': packId,
        'last_used_at': lastUsedAt.toUtc().toIso8601String(),
        'use_count': useCount,
      };

  factory EmojiRecentRecord.fromJson(Map<String, dynamic> json) {
    final key = EmojiAssetKey.parse(json['asset_key']?.toString() ?? '');
    final parsedDate =
        DateTime.tryParse(json['last_used_at']?.toString() ?? '');
    final parsedCount = json['use_count'] is num
        ? (json['use_count'] as num).toInt()
        : int.tryParse(json['use_count']?.toString() ?? '');
    if (parsedDate == null || parsedCount == null || parsedCount < 1) {
      throw const FormatException('Recent 记录字段无效');
    }
    return EmojiRecentRecord(
      assetKey: key.serialized,
      packId: json['pack_id']?.toString(),
      lastUsedAt: parsedDate.toUtc(),
      useCount: parsedCount,
    );
  }
}
