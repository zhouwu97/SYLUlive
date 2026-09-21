import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' hide ZLibDecoder;
import 'package:crypto/crypto.dart';

import '../domain/emoji_feature_flags.dart';
import '../domain/emoji_local_id.dart';
import '../domain/emoji_pack.dart';
import '../domain/emoji_pack_installation.dart';
import '../domain/emoji_pack_limits.dart';
import '../domain/emoji_pack_manifest.dart';
import 'emoji_pack_installer.dart';

class EmojiPackImporter {
  EmojiPackImporter(this.installer,
      {this.flags = EmojiFeatureFlags.production});
  final EmojiPackInstaller installer;
  final EmojiFeatureFlags flags;

  Future<EmojiPackInstallation> importFile(File file) async {
    if (!flags.customPackImport) throw StateError('外部表情包导入尚未开放');
    if (!file.path.toLowerCase().endsWith('.sylupack')) {
      throw const FormatException('请选择 .sylupack 文件');
    }
    if (await file.length() > EmojiPackLimits.maxArchiveBytes) {
      throw const FormatException('压缩包过大');
    }
    final bytes = await file.readAsBytes();
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
    if (manifestEntry == null) throw const FormatException('缺少 manifest.json');
    final raw = jsonDecode(utf8.decode(_extract(manifestEntry))) as Map;
    final source = EmojiPackManifest.fromJson(Map<String, dynamic>.from(raw));
    if (entries.length != source.assets.length + 1 ||
        source.assets.any((e) => !entries.containsKey(e.path))) {
      throw const FormatException('ZIP 文件清单与 Manifest 不一致');
    }
    // Manifest 中的 official、packId 不授予官方身份。本地包身份由随机 UUID 生成，
    // 只有「重新导入同一个文件」才沿用已有身份，判据是源文件内容的 SHA-256。
    // 这样两个包可以声明同一个外部 pack_id，也不会互相顶掉或冒领身份。
    final sourceSha256 = sha256.convert(bytes).toString();
    final previous = (await installer.store.load())
        .where((p) =>
            p.trustLevel == EmojiPackTrustLevel.localUntrusted &&
            p.importSourceSha256 == sourceSha256)
        .map((p) => p.packId)
        .firstOrNull;
    final localId = previous ?? 'local-${newEmojiLocalId()}';
    final manifest = EmojiPackManifest(
        schemaVersion: source.schemaVersion,
        packId: localId,
        version: source.version,
        totalSize: source.totalSize,
        assets: source.assets);
    return installer.install(
        manifest: manifest,
        name: raw['name']?.toString() ?? source.packId,
        trustLevel: EmojiPackTrustLevel.localUntrusted,
        readAsset: (asset) async => _extract(entries[asset.path]!),
        externalPackId: source.packId,
        importSourceSha256: sourceSha256);
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
