import 'dart:typed_data';
import 'package:image/image.dart' as image;

Uint8List buildEmojiThumbnail((Uint8List, int) input) {
  final (bytes, size) = input;
  final info = image.findDecoderForData(bytes)?.startDecode(bytes);
  if (info == null ||
      info.width < 1 ||
      info.height < 1 ||
      info.width > 4096 ||
      info.height > 4096 ||
      bytes.length > 15 * 1024 * 1024) {
    throw const FormatException('缩略图资源无效或超限');
  }
  final decoded = image.decodeImage(bytes, frame: 0);
  if (decoded == null) throw const FormatException('缩略图生成失败');
  final ratio = decoded.width > decoded.height
      ? size / decoded.width
      : size / decoded.height;
  final output = ratio < 1
      ? image.copyResize(decoded,
          width: (decoded.width * ratio).round().clamp(1, size),
          height: (decoded.height * ratio).round().clamp(1, size),
          interpolation: image.Interpolation.average)
      : decoded;
  return Uint8List.fromList(image.encodePng(output));
}
