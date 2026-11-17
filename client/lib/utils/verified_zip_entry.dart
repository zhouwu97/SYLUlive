import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' hide ZLibDecoder;

/// 调用方先核对目录声明的体积上限；这里限制实际输出并校验 ZIP 原生 CRC。
Uint8List readVerifiedZipEntry(ZipFileHeader entry) {
  final raw = entry.file!.getStream(decompress: false).toUint8List();
  final sink = _EntrySink(entry.uncompressedSize);
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
      !_DecodedEntry(entry, bytes).verifyCrc32()) {
    throw const FormatException('ZIP 内容长度或 CRC 校验失败');
  }
  return bytes;
}

class _EntrySink extends ByteConversionSinkBase {
  _EntrySink(this.limit);
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

// verifyCrc32 只读取已限流的结果，避免库内部再次无上限地解压。
class _DecodedEntry extends ZipFile {
  _DecodedEntry(ZipFileHeader entry, this.bytes) : super(entry) {
    crc32 = entry.crc32;
  }
  final Uint8List bytes;

  @override
  InputStream getStream({bool decompress = true}) => InputMemoryStream(bytes);
}
