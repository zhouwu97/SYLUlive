import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' hide ZLibDecoder;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as path;

import '../domain/emoji_feature_flags.dart';
import '../domain/emoji_local_id.dart';
import '../domain/emoji_pack.dart';
import '../domain/emoji_pack_installation.dart';
import '../domain/emoji_pack_limits.dart';
import '../domain/emoji_pack_manifest.dart';
import 'emoji_pack_installer.dart';
import 'emoji_thumbnail.dart';

/// 预览只持有已校验内容，用户确认之前不写安装目录。
class PreparedEmojiPack {
  const PreparedEmojiPack(
      {required this.manifest,
      required this.name,
      required this.contents,
      required this.sourceSha256,
      this.thumbnails = const {},
      this.externalPackId});
  final EmojiPackManifest manifest;
  final String name;
  final Map<String, Uint8List> contents;
  final String sourceSha256;
  final String? externalPackId;
  final Map<String, Uint8List> thumbnails;
}

class EmojiPackImporter {
  EmojiPackImporter(this.installer,
      {this.flags = EmojiFeatureFlags.production});
  final EmojiPackInstaller installer;
  final EmojiFeatureFlags flags;

  void _ensureEnabled() {
    if (!flags.customPackImport) throw StateError('外部表情包导入尚未开放');
  }

  Future<EmojiPackInstallation> importFile(File file) async =>
      installPrepared(await prepareFile(file));

  Future<PreparedEmojiPack> prepareFile(File file) async {
    _ensureEnabled();
    final extension = path.extension(file.path).toLowerCase();
    if (!['.sylupack', '.zip'].contains(extension)) {
      throw const FormatException('请选择 ZIP 或 .sylupack 表情包');
    }
    if (await file.length() > EmojiPackLimits.maxArchiveBytes) {
      throw const FormatException('压缩包过大');
    }
    return compute(_prepareArchiveFile,
        (file.path, path.basenameWithoutExtension(file.path), extension));
  }

  Future<PreparedEmojiPack> prepareImages(List<File> files) async {
    _ensureEnabled();
    if (files.isEmpty || files.length > EmojiPackLimits.maxAssetCount) {
      throw const FormatException('请选择 1–500 张图片');
    }
    return compute(_prepareImageFiles, files.map((file) => file.path).toList());
  }

  static Uint8List _readBounded(File file, int limit) {
    final handle = file.openSync();
    try {
      final bytes = handle.readSync(min(limit + 1, handle.lengthSync()));
      if (bytes.length > limit || handle.lengthSync() > limit) {
        throw const FormatException('文件大小超出限制');
      }
      return bytes;
    } finally {
      handle.closeSync();
    }
  }

  static PreparedEmojiPack _prepareArchiveFile((String, String, String) input) {
    final (file, name, extension) = input;
    return _prepareArchive((
      _readBounded(File(file), EmojiPackLimits.maxArchiveBytes),
      name,
      extension
    ));
  }

  static PreparedEmojiPack _prepareImageFiles(List<String> files) {
    var total = 0;
    final contents = <String, Uint8List>{};
    for (var i = 0; i < files.length; i++) {
      final file = File(files[i]);
      if (file.lengthSync() > EmojiPackLimits.maxSingleAssetBytes) {
        throw const FormatException('单张图片不能超过 15 MB');
      }
      final bytes = _readBounded(file, EmojiPackLimits.maxSingleAssetBytes);
      total += bytes.length;
      if (bytes.length > EmojiPackLimits.maxSingleAssetBytes ||
          total > EmojiPackLimits.maxExpandedBytes) {
        throw const FormatException('图片总大小超出限制');
      }
      contents['$i/${path.basename(file.path)}'] = bytes;
    }
    return _prepareLooseImages(contents);
  }

  Future<EmojiPackInstallation> installPrepared(PreparedEmojiPack prepared,
      {String? name, bool Function()? isCurrent}) async {
    _ensureEnabled();
    void ensureCurrent() {
      if (isCurrent != null && !isCurrent()) throw StateError('账号已切换，请重新导入');
    }

    ensureCurrent();
    final source = prepared.manifest;
    final previous = (await installer.store.load())
        .where((p) =>
            p.trustLevel == EmojiPackTrustLevel.localUntrusted &&
            p.importSourceSha256 == prepared.sourceSha256)
        .firstOrNull;
    ensureCurrent();
    final displayName = (name ?? previous?.name ?? prepared.name).trim();
    if (displayName.isEmpty) throw const FormatException('请填写表情包名称');
    final installed = await installer.install(
        manifest: previous?.manifest ??
            EmojiPackManifest(
                schemaVersion: 1,
                packId: 'local-${newEmojiLocalId()}',
                version: source.version,
                totalSize: source.totalSize,
                assets: source.assets),
        name: displayName,
        trustLevel: EmojiPackTrustLevel.localUntrusted,
        readAsset: (asset) async {
          ensureCurrent();
          final sourceAsset =
              source.assets.firstWhere((item) => item.sha256 == asset.sha256);
          return prepared.contents[sourceAsset.path]!;
        },
        externalPackId: prepared.externalPackId,
        importSourceSha256: prepared.sourceSha256);
    ensureCurrent();
    if (installed.enabled && installed.name == displayName) return installed;
    return installer.store.exclusive(() async {
      ensureCurrent();
      final index = await installer.store.readIndex();
      final latest = EmojiPackInstallation.fromJson(Map<String, dynamic>.from(
          (index['packs'] as Map)[installed.packId] as Map));
      ensureCurrent();
      return installer.store
          .commit(latest.copyWith(name: displayName, enabled: true));
    });
  }

  static PreparedEmojiPack _prepareArchive((Uint8List, String, String) input) {
    final (bytes, fileName, extension) = input;
    final directory = ZipDirectory()..read(InputMemoryStream(bytes));
    if (directory.fileHeaders.isEmpty ||
        directory.fileHeaders.length > EmojiPackLimits.maxAssetCount * 2 + 1) {
      throw const FormatException('ZIP 文件数量无效');
    }
    final entries = <String, ZipFileHeader>{};
    final names = <String>{};
    var expanded = 0;
    for (final header in directory.fileHeaders) {
      final type = (header.externalFileAttributes >> 16) & 0xf000;
      final name = header.filename;
      final isDirectory = name.endsWith('/');
      final path = isDirectory ? name.substring(0, name.length - 1) : name;
      _validatePath(path);
      if (!names.add(path.toLowerCase()) ||
          (type != 0 && type != 0x8000 && type != 0x4000) ||
          header.generalPurposeBitFlag & 1 != 0 ||
          (header.compressionMethod != 0 && header.compressionMethod != 8) ||
          header.file?.filename != name) {
        throw const FormatException('ZIP 含重复路径、链接或不支持的条目');
      }
      expanded += header.uncompressedSize;
      final limit = name == 'manifest.json'
          ? EmojiPackLimits.maxManifestBytes
          : EmojiPackLimits.maxSingleAssetBytes;
      if (header.uncompressedSize > limit ||
          expanded > EmojiPackLimits.maxExpandedBytes ||
          (header.uncompressedSize > 1024 * 1024 &&
              header.uncompressedSize > max(1, header.compressedSize) * 200)) {
        throw const FormatException('ZIP 解压大小或压缩比超出限制');
      }
      if (!isDirectory) entries[name] = header;
    }
    final manifestEntry = entries['manifest.json'];
    if (manifestEntry == null) {
      if (extension == '.sylupack') {
        throw const FormatException('缺少 manifest.json');
      }
      final images = <String, Uint8List>{};
      for (final entry in entries.entries) {
        if (entry.key.startsWith('__MACOSX/') ||
            path.posix.basename(entry.key) == '.DS_Store') {
          continue;
        }
        if (!['.png', '.jpg', '.jpeg', '.gif']
            .contains(path.posix.extension(entry.key).toLowerCase())) {
          throw const FormatException('ZIP 中只能包含 PNG、JPG 或 GIF 图片');
        }
        images[entry.key] = _extract(entry.value);
      }
      return _prepareLooseImages(images, name: fileName);
    }
    final raw = jsonDecode(utf8.decode(_extract(manifestEntry))) as Map;
    final source = EmojiPackManifest.fromJson(Map<String, dynamic>.from(raw));
    if (entries.length != source.assets.length + 1 ||
        source.assets.any((e) => !entries.containsKey(e.path))) {
      throw const FormatException('ZIP 文件清单与 Manifest 不一致');
    }
    if (source.assets.isEmpty ||
        source.assets.length > EmojiPackLimits.maxAssetCount) {
      throw const FormatException('表情包数量超出限制');
    }
    final contents = <String, Uint8List>{};
    for (final asset in source.assets) {
      final content = _extract(entries[asset.path]!);
      validateEmojiPackImage((asset, content));
      contents[asset.path] = content;
    }
    return PreparedEmojiPack(
        manifest: source,
        name: raw['name']?.toString() ?? fileName,
        contents: contents,
        thumbnails: {
          for (final asset in source.assets)
            asset.path: buildEmojiThumbnail((contents[asset.path]!, 256))
        },
        sourceSha256: sha256.convert(bytes).toString(),
        externalPackId: source.packId);
  }

  static PreparedEmojiPack _prepareLooseImages(Map<String, Uint8List> input,
      {String name = '我的表情包'}) {
    if (input.isEmpty || input.length > EmojiPackLimits.maxAssetCount) {
      throw const FormatException('请选择 1–500 张图片');
    }
    final assets = <EmojiManifestAsset>[];
    final contents = <String, Uint8List>{};
    final hashes = <String>{};
    var total = 0;
    for (final entry in input.entries) {
      final bytes = entry.value;
      if (bytes.length > EmojiPackLimits.maxSingleAssetBytes) {
        throw const FormatException('单张图片不能超过 15 MB');
      }
      final hash = sha256.convert(bytes).toString();
      if (!hashes.add(hash)) continue;
      final decoder = image.findDecoderForData(bytes);
      final mime = switch (decoder) {
        image.PngDecoder() => 'image/png',
        image.JpegDecoder() => 'image/jpeg',
        image.GifDecoder() => 'image/gif',
        _ => throw const FormatException('仅支持 PNG、JPG 和 GIF 图片'),
      };
      final info = decoder!.startDecode(bytes);
      if (info == null) throw const FormatException('图片已损坏');
      final id = 'image-${assets.length + 1}';
      final extension = mime == 'image/png'
          ? 'png'
          : mime == 'image/gif'
              ? 'gif'
              : 'jpg';
      final asset = EmojiManifestAsset(
          id: id,
          path: 'assets/$id.$extension',
          name: path.posix.basenameWithoutExtension(entry.key),
          sha256: hash,
          mimeType: mime,
          fileSize: bytes.length,
          width: info.width,
          height: info.height,
          animated: info.numFrames > 1);
      validateEmojiPackImage((asset, bytes));
      total += bytes.length;
      if (total > EmojiPackLimits.maxExpandedBytes) {
        throw const FormatException('图片总大小超出限制');
      }
      assets.add(asset);
      contents[asset.path] = bytes;
    }
    // 对最终图片集合计算身份，重复选图/换 ZIP 文件名不会制造重复安装。
    final digest = sha256
        .convert(utf8.encode(jsonEncode(hashes.toList()..sort())))
        .toString();
    return PreparedEmojiPack(
        manifest: EmojiPackManifest(
            schemaVersion: 1,
            packId: 'local-import',
            version: 1,
            totalSize: total,
            assets: assets),
        name: name,
        contents: contents,
        thumbnails: {
          for (final asset in assets)
            asset.path: buildEmojiThumbnail((contents[asset.path]!, 256))
        },
        sourceSha256: digest);
  }

  static void _validatePath(String path) {
    EmojiManifestAsset(
            id: 'path',
            path: path,
            name: 'path',
            sha256: '0' * 64,
            mimeType: 'image/png',
            fileSize: 0)
        .validate();
  }

  static Uint8List _extract(ZipFileHeader entry) {
    final raw = entry.file!.getStream(decompress: false).toUint8List();
    final sink = _BoundedSink(entry.uncompressedSize);
    if (entry.compressionMethod == 0) {
      sink.add(raw);
    } else {
      final decoder = ZLibDecoder(raw: true).startChunkedConversion(sink);
      for (var offset = 0; offset < raw.length; offset += 4096) {
        decoder.add(raw.sublist(offset, min(raw.length, offset + 4096)));
      }
      decoder.close();
    }
    final bytes = sink.bytes.takeBytes();
    if (bytes.length != entry.uncompressedSize ||
        getCrc32(bytes) != entry.crc32) {
      throw const FormatException('ZIP 内容长度或 CRC 校验失败');
    }
    return bytes;
  }
}

class _BoundedSink extends ByteConversionSinkBase {
  _BoundedSink(this.limit);
  final int limit;
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > limit) {
      throw const FormatException('ZIP 实际解压大小超出声明');
    }
    bytes.add(chunk);
  }

  @override
  void close() {}
}
