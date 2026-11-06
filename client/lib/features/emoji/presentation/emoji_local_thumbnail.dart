import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import '../application/emoji_thumbnail.dart';
import '../data/emoji_pack_local_store.dart';
import '../domain/emoji_pack_installation.dart';
import '../domain/emoji_pack_manifest.dart';
import 'official_emoji_previews.dart';

ImageProvider emojiInstalledThumbnail(EmojiPackLocalStore store,
    EmojiPackInstallation pack, EmojiManifestAsset asset) {
  final officialPreview = officialEmojiPreview(pack, asset);
  if (officialPreview != null) return AssetImage(officialPreview);
  return EmojiLocalThumbnail(
      File(
          '${store.versionDirectory(pack.packId, pack.version).path}/${asset.path}'),
      store.thumbnailFile(pack, asset));
}

/// 历史包无磁盘缩略图时只在内存生成，避免预览在删除后重新创建安装目录。
class EmojiLocalThumbnail extends ImageProvider<EmojiLocalThumbnail> {
  const EmojiLocalThumbnail(this.source, this.thumbnail);
  final File source, thumbnail;
  @override
  Future<EmojiLocalThumbnail> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
          EmojiLocalThumbnail key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(key, decode), scale: 1);
  Future<ui.Codec> _load(
      EmojiLocalThumbnail key, ImageDecoderCallback decode) async {
    try {
      if (await source.length() > 15 * 1024 * 1024) {
        throw const FormatException('表情图片过大');
      }
      if (await thumbnail.exists()) {
        try {
          if (await thumbnail.length() > 1024 * 1024) {
            throw const FormatException('缩略图无效');
          }
          return await decode(await ui.ImmutableBuffer.fromUint8List(
              await thumbnail.readAsBytes()));
        } catch (_) {/* 派生缓存损坏时从已安装发送图恢复。 */}
      }
      final bytes =
          await compute(buildEmojiThumbnail, (await source.readAsBytes(), 256));
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (_) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is EmojiLocalThumbnail &&
      source.path == other.source.path &&
      thumbnail.path == other.thumbnail.path;
  @override
  int get hashCode => Object.hash(source.path, thumbnail.path);
}
