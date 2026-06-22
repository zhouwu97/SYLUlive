import 'package:fast_gbk/fast_gbk.dart';

class Gb18030FormEncoder {
  /// Encodes a map of form fields into a URL-encoded string using GB18030 encoding,
  /// matching the exact behavior of Python's `urllib.parse.quote_plus` with `gb18030`.
  /// Spaces are encoded as `+`.
  static List<int> encodeFormBody(Map<String, String> data) {
    final encoded = <String>[];
    for (final entry in data.entries) {
      final kEnc = _quotePlus(gbk.encode(entry.key));
      final vEnc = _quotePlus(gbk.encode(entry.value));
      encoded.add('$kEnc=$vEnc');
    }
    final bodyStr = encoded.join('&');
    return bodyStr.codeUnits; // ASCII bytes
  }

  static String _quotePlus(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      // Alphanumeric and safe characters: a-zA-Z0-9_.-
      if ((byte >= 0x61 && byte <= 0x7A) || // a-z
          (byte >= 0x41 && byte <= 0x5A) || // A-Z
          (byte >= 0x30 && byte <= 0x39) || // 0-9
          byte == 0x5F || // _
          byte == 0x2E || // .
          byte == 0x2D) { // -
        buffer.writeCharCode(byte);
      } else if (byte == 0x20) { // space
        buffer.writeCharCode(0x2B); // +
      } else {
        buffer.write('%');
        buffer.write(byte.toRadixString(16).padLeft(2, '0').toUpperCase());
      }
    }
    return buffer.toString();
  }
}
