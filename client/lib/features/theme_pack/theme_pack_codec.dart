import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';

import '../../utils/verified_zip_entry.dart';
import 'theme_font_registry.dart';
import 'theme_manifest.dart';

class PreparedThemePack {
  const PreparedThemePack(this.manifest, this.contents);
  final ThemeManifest manifest;
  final Map<String, Uint8List> contents;
}

abstract final class ThemePackCodec {
  static const maxPackageBytes = 48 * 1024 * 1024;
  static const maxExpandedBytes = 96 * 1024 * 1024;
  static const maxManifestBytes = 64 * 1024;

  static Future<PreparedThemePack> readFile(String file,
      {required String appVersion}) async {
    final prepared = await Isolate.run(() async {
      final buffer = BytesBuilder(copy: false);
      try {
        await for (final chunk in File(file).openRead(0, maxPackageBytes + 1)) {
          buffer.add(chunk);
        }
      } on FileSystemException {
        throw const ThemePackError('theme_zip_invalid', 'file');
      }
      return _readArchive(buffer.takeBytes(), appVersion);
    });
    await _validateImages(prepared);
    await ThemeFontRegistry.probePackFont(prepared.manifest, prepared.contents);
    return prepared;
  }

  static Future<PreparedThemePack> decode(Uint8List bytes,
      {required String appVersion}) async {
    final prepared =
        await Isolate.run(() => _readArchive(bytes, appVersion, false));
    await _validateImages(prepared);
    await ThemeFontRegistry.probePackFont(prepared.manifest, prepared.contents);
    return prepared;
  }

  /// 商城规范包已在服务端做过完整校验并由下载器核对过一次 SHA-256，仅解包校验 ZIP CRC32 并注册字体。
  static Future<PreparedThemePack> decodeStorePackage(
    Uint8List bytes, {
    required String appVersion,
  }) async {
    final prepared =
        await Isolate.run(() => _readArchive(bytes, appVersion, true));
    await ThemeFontRegistry.probePackFont(prepared.manifest, prepared.contents);
    return prepared;
  }

  static PreparedThemePack _readArchive(
    Uint8List bytes,
    String appVersion, [
    bool preserveStoreSource = false,
  ]) {
    if (bytes.length > maxPackageBytes) {
      throw const ThemePackError('theme_too_large');
    }
    try {
      final directory = ZipDirectory()..read(InputMemoryStream(bytes));
      if (directory.filePosition < 0 ||
          directory.numberOfThisDisk != 0 ||
          directory.diskWithTheStartOfTheCentralDirectory != 0 ||
          directory.fileHeaders.length !=
              directory.totalCentralDirectoryEntries ||
          directory.centralDirectoryOffset + directory.centralDirectorySize >
              directory.filePosition) {
        throw const ThemePackError('theme_zip_invalid');
      }
      ZipFileHeader entry(String name, {bool manifest = false}) {
        final matches = directory.fileHeaders
            .where((header) => header.filename == name)
            .toList();
        if (matches.isEmpty) {
          throw ThemePackError(
              manifest ? 'theme_manifest_invalid' : 'theme_asset_missing',
              name);
        }
        if (matches.length != 1) {
          throw const ThemePackError('theme_zip_invalid');
        }
        final header = matches.single;
        final type = (header.externalFileAttributes >> 16) & 0xf000;
        if (header.file == null ||
            header.file!.filename != name ||
            header.generalPurposeBitFlag & 1 != 0 ||
            header.file!.flags & 1 != 0 ||
            ![0, 8].contains(header.compressionMethod) ||
            header.file!.compressionMethod !=
                (header.compressionMethod == 0
                    ? CompressionType.none
                    : CompressionType.deflate) ||
            (type != 0 && type != 0x8000) ||
            header.file!.crc32 != header.crc32) {
          throw ThemePackError('theme_zip_invalid', name);
        }
        return header;
      }

      final description = entry('manifest.json', manifest: true);
      if (description.uncompressedSize > maxManifestBytes) {
        throw const ThemePackError('theme_manifest_invalid', 'manifest.json');
      }
      final manifestBytes = readVerifiedZipEntry(description);
      late Object? document;
      try {
        document = jsonDecode(utf8.decode(manifestBytes));
      } on FormatException {
        throw const ThemePackError('theme_manifest_invalid', 'manifest.json');
      }
      final manifest = ThemeManifest.parse(
        document,
        appVersion: appVersion,
        preserveStoreSource: preserveStoreSource,
      );
      final references = <String, List<ThemeAssetKind>>{};
      for (final asset in manifest.assets) {
        references.putIfAbsent(asset.path, () => []).add(asset.kind);
      }
      final headers = {for (final name in references.keys) name: entry(name)};
      final total = manifestBytes.length +
          headers.values
              .fold<int>(0, (sum, item) => sum + item.uncompressedSize);
      if (total > maxExpandedBytes) {
        throw const ThemePackError('theme_too_large');
      }
      final contents = <String, Uint8List>{};
      for (final item in headers.entries) {
        for (final kind in references[item.key]!) {
          if (item.value.uncompressedSize > _assetLimit(kind)) {
            throw ThemePackError(
                kind == ThemeAssetKind.font
                    ? 'theme_font_invalid'
                    : 'theme_image_invalid',
                item.key);
          }
        }
        final content = readVerifiedZipEntry(item.value);
        if (references[item.key]!.contains(ThemeAssetKind.font)) {
          _validateFont(content, item.key);
        }
        contents[item.key] = content;
      }
      return PreparedThemePack(manifest, contents);
    } on ThemePackError {
      rethrow;
    } on FormatException {
      throw const ThemePackError('theme_zip_invalid');
    } on RangeError {
      throw const ThemePackError('theme_zip_invalid');
    } on StateError {
      throw const ThemePackError('theme_zip_invalid');
    }
  }

  static int _assetLimit(ThemeAssetKind kind) => switch (kind) {
        ThemeAssetKind.preview || ThemeAssetKind.header => 2 * 1024 * 1024,
        ThemeAssetKind.wallpaper => 8 * 1024 * 1024,
        ThemeAssetKind.icon => 256 * 1024,
        ThemeAssetKind.launcher => 1024 * 1024,
        ThemeAssetKind.sticker => 512 * 1024,
        ThemeAssetKind.illustration => 1024 * 1024,
        ThemeAssetKind.font => 24 * 1024 * 1024,
      };

  static void _validateFont(Uint8List bytes, String path) {
    bool invalid() => throw ThemePackError('theme_font_invalid', path);
    if (bytes.length < 12) invalid();
    final data = ByteData.sublistView(bytes);
    if (![0x00010000, 0x4f54544f].contains(data.getUint32(0))) invalid();
    final count = data.getUint16(4);
    if (count == 0 || 12 + count * 16 > bytes.length) invalid();
    for (var i = 0; i < count; i++) {
      final offset = data.getUint32(12 + i * 16 + 8);
      final length = data.getUint32(12 + i * 16 + 12);
      if (offset + length > bytes.length) invalid();
    }
  }

  // 原生描述符与图片解码在主 isolate 异步执行，ZIP 和 JSON 在工作 isolate 处理。
  static Future<void> _validateImages(PreparedThemePack pack) async {
    final references = <String, Set<ThemeAssetKind>>{};
    for (final asset in pack.manifest.assets) {
      if (asset.kind != ThemeAssetKind.font) {
        references.putIfAbsent(asset.path, () => {}).add(asset.kind);
      }
    }
    for (final item in references.entries) {
      await _validateImageBytes(
        pack.contents[item.key]!,
        item.key,
        item.value,
        checkExtensionMatch: true,
      );
    }
  }

  /// 本机选择图片（壁纸、页头背景、贴纸、图标）的信任边界校验。
  static Future<void> validateLocalImageFile(
    String filePath,
    ThemeAssetKind kind,
  ) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw ThemePackError('theme_asset_missing', filePath);
    }
    final limit = _assetLimit(kind);
    final length = await file.length();
    if (length == 0 || length > limit) {
      throw ThemePackError('theme_image_invalid', filePath);
    }
    final bytes = await file.readAsBytes();
    await _validateImageBytes(
      bytes,
      filePath,
      {kind},
      checkExtensionMatch: false,
    );
  }

  static Future<void> _validateImageBytes(
    Uint8List bytes,
    String field,
    Set<ThemeAssetKind> kinds, {
    required bool checkExtensionMatch,
  }) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      final png = bytes.length >= 8 &&
          bytes[0] == 137 &&
          bytes[1] == 80 &&
          bytes[2] == 78 &&
          bytes[3] == 71;
      final jpeg = bytes.length >= 3 &&
          bytes[0] == 255 &&
          bytes[1] == 216 &&
          bytes[2] == 255;
      final webp = bytes.length >= 12 &&
          ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
          ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP';
      if (!png && !jpeg && !webp) {
        throw const FormatException('不支持的图片格式');
      }
      if (checkExtensionMatch &&
          !(field.endsWith('.png') && png ||
              field.endsWith('.jpg') && jpeg ||
              field.endsWith('.webp') && webp)) {
        throw const FormatException('图片格式与后缀不符');
      }
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final w = descriptor.width;
      final h = descriptor.height;
      for (final kind in kinds) {
        final valid = switch (kind) {
          ThemeAssetKind.preview => w == 1080 && h == 2340,
          ThemeAssetKind.icon => !jpeg && w == h && w >= 48 && w <= 256,
          ThemeAssetKind.launcher => !jpeg && w == h && w >= 432 && w <= 1024,
          ThemeAssetKind.wallpaper => w <= 4096 && h <= 4096,
          ThemeAssetKind.header => w <= 2048 && h <= 2048,
          ThemeAssetKind.sticker ||
          ThemeAssetKind.illustration =>
            !jpeg && w <= 1024 && h <= 1024,
          ThemeAssetKind.font => true,
        };
        if (!valid) throw const FormatException('图片尺寸不合规');
      }
      codec = await descriptor.instantiateCodec();
      if (codec.frameCount != 1) throw const FormatException('仅支持静态图片');
      image = (await codec.getNextFrame()).image;
      if (kinds.contains(ThemeAssetKind.launcher)) {
        final rgba =
            await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        for (var i = 3; i < rgba!.lengthInBytes; i += 4) {
          if (rgba.getUint8(i) != 255) {
            throw const FormatException('桌面图标必须不透明');
          }
        }
      }
    } catch (_) {
      throw ThemePackError('theme_image_invalid', field);
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  static Future<Uint8List> encode(
          ThemeManifest manifest, Map<String, Uint8List> contents) =>
      Isolate.run(() {
        final archive = Archive();
        final json = utf8.encode(jsonEncode(manifest.data));
        archive.addFile(ArchiveFile('manifest.json', json.length, json));
        for (final path in manifest.assets.map((asset) => asset.path).toSet()) {
          final bytes = contents[path]!;
          archive.addFile(ArchiveFile(path, bytes.length, bytes));
        }
        return Uint8List.fromList(ZipEncoder().encode(archive));
      });
}
