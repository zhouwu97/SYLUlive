import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:image_picker/image_picker.dart';

import 'public_image_upload_policy.dart';

typedef JpegBytesCompressor = Uint8List Function(Uint8List source);

/// 公开上传时实际使用的文件；压缩成功时需要在请求结束后清理临时文件。
class PreparedPublicImage {
  const PreparedPublicImage({
    required this.file,
    required this.isTemporary,
  });

  final XFile file;
  final bool isTemporary;

  Future<void> dispose() async {
    if (!isTemporary || file.path.isEmpty) return;
    try {
      await File(file.path).delete();
      final parent = File(file.path).parent;
      if (await parent.exists()) {
        await parent.delete();
      }
    } catch (_) {
      // 临时文件清理不能影响已完成或已失败的上传请求。
    }
  }
}

/// 对公开 JPEG 执行受限的上传前压缩。
///
/// 私有媒体、GIF 和 PNG 不应调用该类。编码失败必须回退原始文件，服务器的
/// MIME、尺寸与体积校验仍是最终安全边界。
class PublicImageCompressor {
  PublicImageCompressor({JpegBytesCompressor? compress})
      : _compress = compress ?? compressJpegBytes;

  final JpegBytesCompressor _compress;

  Future<PreparedPublicImage> prepare(XFile source) async {
    try {
      final sourcePath = source.path;
      Uint8List? sourceBytes;
      int fileSize;
      Uint8List header;

      final diskFile = File(sourcePath);
      if (sourcePath.isNotEmpty && await diskFile.exists()) {
        fileSize = await diskFile.length();
        header = await _readHeader(diskFile);
      } else {
        sourceBytes = await source.readAsBytes();
        fileSize = sourceBytes.length;
        header = sourceBytes;
      }

      final decision = PublicImageUploadPolicy.decide(
        bytes: header,
        fileSize: fileSize,
      );
      if (!decision.shouldCompress) {
        return PreparedPublicImage(file: source, isTemporary: false);
      }

      sourceBytes ??= await diskFile.readAsBytes();
      final compressed = _compress(sourceBytes);
      if (compressed.isEmpty) {
        return PreparedPublicImage(file: source, isTemporary: false);
      }

      final tempDir = await Directory.systemTemp.createTemp(
        'sylulive-public-image-',
      );
      final output = File('${tempDir.path}${Platform.pathSeparator}image.jpg');
      await output.writeAsBytes(compressed, flush: true);
      return PreparedPublicImage(
        file: XFile(
          output.path,
          name: _compressedName(source.name),
          mimeType: 'image/jpeg',
        ),
        isTemporary: true,
      );
    } catch (_) {
      return PreparedPublicImage(file: source, isTemporary: false);
    }
  }

  static Uint8List compressJpegBytes(Uint8List source) {
    final decoded = image.decodeJpg(source);
    if (decoded == null) {
      throw const FormatException('JPEG 解码失败');
    }
    final longestEdge =
        decoded.width > decoded.height ? decoded.width : decoded.height;
    final resized = longestEdge <= PublicImageUploadPolicy.maxDimension
        ? decoded
        : image.copyResize(
            decoded,
            width: (decoded.width *
                    PublicImageUploadPolicy.maxDimension /
                    longestEdge)
                .round(),
            height: (decoded.height *
                    PublicImageUploadPolicy.maxDimension /
                    longestEdge)
                .round(),
          );
    return Uint8List.fromList(
      image.encodeJpg(resized, quality: PublicImageUploadPolicy.jpegQuality),
    );
  }

  static Future<Uint8List> _readHeader(File file) async {
    final handle = await file.open(mode: FileMode.read);
    try {
      final length = await handle.length();
      return await handle.read(length < 4096 ? length : 4096);
    } finally {
      await handle.close();
    }
  }

  static String _compressedName(String name) {
    final stem = name.trim().replaceAll(RegExp(r'\.[^.]+$'), '');
    return '${stem.isEmpty ? 'upload' : stem}.jpg';
  }
}
