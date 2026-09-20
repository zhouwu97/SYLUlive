import '../../../widgets/emoji/sticker_catalog.dart';
import '../domain/emoji_asset_key.dart';
import '../domain/emoji_recent_record.dart';

/// 将 `emoji_recent_v1` 的字符串列表转换为结构化 Recent。
///
/// 旧值没有时间和计数信息，因此按原列表顺序分配递减的时间戳，并把
/// 每项的计数初始化为 1；迁移只读旧数据，不在这里清理旧键。
class LegacyRecentAdapter {
  const LegacyRecentAdapter();

  List<EmojiRecentRecord> adapt(
    Iterable<String> legacyValues, {
    DateTime? migratedAt,
  }) {
    final baseTime = migratedAt ?? DateTime.now();
    final records = <EmojiRecentRecord>[];
    final seen = <String>{};
    var offset = 0;
    for (final raw in legacyValues) {
      final value = raw.trim();
      if (value.isEmpty || value.contains(':')) continue;
      final key = _keyFor(value);
      if (key == null) continue;
      if (!seen.add(key.serialized)) continue;
      records.add(
        EmojiRecentRecord(
          assetKey: key.serialized,
          packId: key.packId,
          lastUsedAt: baseTime.subtract(Duration(microseconds: offset++)),
          useCount: 1,
        ),
      );
    }
    return records;
  }

  EmojiAssetKey? _keyFor(String value) {
    final sticker = appStickerById(value);
    if (sticker != null) {
      const marker = 'assets/images/stickers/';
      final start = sticker.thumbnailAsset.indexOf(marker);
      final rest = start < 0
          ? ''
          : sticker.thumbnailAsset.substring(start + marker.length);
      final slash = rest.indexOf('/');
      final packId = slash > 0 ? rest.substring(0, slash) : 'builtin';
      return EmojiAssetKey(
        namespace: 'builtin',
        packId: packId,
        assetId: sticker.id,
      );
    }
    // 旧内置贴图 ID 是十六进制摘要；若当前 APK 已不再包含它，
    // 不能把摘要误当成 Unicode 资源继续展示。
    if (RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(value)) return null;
    return EmojiAssetKey(namespace: 'unicode', assetId: value);
  }
}
