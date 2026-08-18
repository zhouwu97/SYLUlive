import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 轻量级图片头部尺寸解析器。
///
/// 仅读取本地文件前 2KB~4KB 字节流即可提取 PNG/JPEG/GIF/WebP 真实宽高，
/// 避免将数 MB 的高分辨率图片全量读入 Dart Heap (`readAsBytes()`) 或全图解码，
/// 消除列表与私信快速滑动时的内存毛刺。
abstract final class ImageHeaderSizeParser {
  /// 从本地文件快速提取尺寸。
  static Future<ui.Size?> parseFileSize(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return null;

    RandomAccessFile? raf;
    try {
      raf = await file.open(mode: FileMode.read);
      final length = await raf.length();
      final readLen = length < 4096 ? length : 4096;
      if (readLen < 10) return null;

      final buffer = await raf.read(readLen);
      return parseBytesSize(buffer);
    } catch (_) {
      return null;
    } finally {
      await raf?.close();
    }
  }

  /// 从字节流中解析尺寸（通常传入前 2KB-4KB 即可）。
  static ui.Size? parseBytesSize(Uint8List bytes) {
    if (bytes.length < 10) return null;

    // 1. PNG 校验与解析
    if (bytes.length >= 24 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      final width = (bytes[16] << 24) |
          (bytes[17] << 16) |
          (bytes[18] << 8) |
          bytes[19];
      final height = (bytes[20] << 24) |
          (bytes[21] << 16) |
          (bytes[22] << 8) |
          bytes[23];
      if (width > 0 && height > 0) {
        return ui.Size(width.toDouble(), height.toDouble());
      }
    }

    // 2. GIF 校验与解析
    if (bytes.length >= 10 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38 &&
        (bytes[4] == 0x37 || bytes[4] == 0x39) &&
        bytes[5] == 0x61) {
      final width = bytes[6] | (bytes[7] << 8);
      final height = bytes[8] | (bytes[9] << 8);
      if (width > 0 && height > 0) {
        return ui.Size(width.toDouble(), height.toDouble());
      }
    }

    // 3. WebP 解析
    if (bytes.length >= 30 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      // VP8X (Extended WebP)
      if (bytes[12] == 0x56 &&
          bytes[13] == 0x50 &&
          bytes[14] == 0x38 &&
          bytes[15] == 0x58 &&
          bytes.length >= 30) {
        final width = 1 + (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16));
        final height = 1 + (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16));
        if (width > 0 && height > 0) {
          return ui.Size(width.toDouble(), height.toDouble());
        }
      }
      // VP8 (Simple lossy)
      if (bytes[12] == 0x56 &&
          bytes[13] == 0x50 &&
          bytes[14] == 0x38 &&
          bytes[15] == 0x20 &&
          bytes.length >= 30) {
        if (bytes[23] == 0x9D && bytes[24] == 0x01 && bytes[25] == 0x2A) {
          final width = (bytes[26] | (bytes[27] << 8)) & 0x3FFF;
          final height = (bytes[28] | (bytes[29] << 8)) & 0x3FFF;
          if (width > 0 && height > 0) {
            return ui.Size(width.toDouble(), height.toDouble());
          }
        }
      }
      // VP8L (Lossless)
      if (bytes[12] == 0x56 &&
          bytes[13] == 0x50 &&
          bytes[14] == 0x38 &&
          bytes[15] == 0x4C &&
          bytes.length >= 25) {
        if (bytes[20] == 0x2F) {
          final b1 = bytes[21];
          final b2 = bytes[22];
          final b3 = bytes[23];
          final b4 = bytes[24];
          final width = 1 + (b1 | ((b2 & 0x3F) << 8));
          final height = 1 + (((b2 >> 6) | (b3 << 2) | ((b4 & 0x0F) << 10)));
          if (width > 0 && height > 0) {
            return ui.Size(width.toDouble(), height.toDouble());
          }
        }
      }
    }

    // 4. JPEG 校验与解析
    if (bytes.length >= 4 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      int offset = 2;
      while (offset < bytes.length - 8) {
        if (bytes[offset] != 0xFF) {
          offset++;
          continue;
        }
        final marker = bytes[offset + 1];
        // 遇到图像主体起始 (SOS) 或结束 (EOI)，停止扫描
        if (marker == 0xDA || marker == 0xD9) break;

        // SOF0..SOF15 帧头（排除 Huffman 表 DHT 0xC4, JPG 0xC8, DAC 0xCC）
        final isSOF = (marker >= 0xC0 && marker <= 0xCF) &&
            marker != 0xC4 &&
            marker != 0xC8 &&
            marker != 0xCC;

        final segmentLength = (bytes[offset + 2] << 8) | bytes[offset + 3];
        if (segmentLength < 2) break;

        if (isSOF && offset + 8 < bytes.length) {
          final height = (bytes[offset + 5] << 8) | bytes[offset + 6];
          final width = (bytes[offset + 7] << 8) | bytes[offset + 8];
          if (width > 0 && height > 0) {
            return ui.Size(width.toDouble(), height.toDouble());
          }
        }
        offset += 2 + segmentLength;
      }
    }

    return null;
  }
}
