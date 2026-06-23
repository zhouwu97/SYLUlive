import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cfb.dart';

class WebVpnUrlCodec {
  static const String _keyStr = 'wrdvpnisthebest!';
  static const String _ivStr = 'wrdvpnisthebest!';

  /// Encrypts a domain name (e.g. 'xg.sylu.edu.cn') using WebVPN's AES-CFB128 algorithm.
  /// The result is a hex string combining the key hex and the ciphertext hex.
  static String encryptDomain(String domain) {
    final key = utf8.encode(_keyStr);
    final iv = utf8.encode(_ivStr);
    final plaintext = utf8.encode(domain);

    final cipher = CFBBlockCipher(
        AESEngine(), 16); // 16 bytes = 128 bit block size for CFB
    cipher.init(
        true,
        ParametersWithIV(
            KeyParameter(Uint8List.fromList(key)), Uint8List.fromList(iv)));

    final encrypted = _processBlocks(cipher, Uint8List.fromList(plaintext));

    final keyHex = _bytesToHex(key);
    final encryptedHex = _bytesToHex(encrypted);

    return '$keyHex$encryptedHex';
  }

  /// Builds a complete WebVPN HTTP URL for a given domain and path.
  static Uri buildHttpUrl({
    required String domain,
    required String path,
  }) {
    final encrypted = encryptDomain(domain);
    // Ensure path starts with a slash
    final safePath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('https://webvpn.sylu.edu.cn/http/$encrypted$safePath');
  }

  static Uint8List _processBlocks(BlockCipher cipher, Uint8List input) {
    var output = Uint8List(input.length);
    var offset = 0;
    while (offset < input.length) {
      if (input.length - offset >= cipher.blockSize) {
        var outBlock = Uint8List(cipher.blockSize);
        cipher.processBlock(input, offset, outBlock, 0);
        output.setRange(offset, offset + cipher.blockSize, outBlock);
        offset += cipher.blockSize;
      } else {
        // Partial block at the end
        // CFB encryption: encrypt the previous ciphertext (or IV) to get keystream
        // PointyCastle's CFBBlockCipher might require full blocks.
        // If we pad the input block with zeros, process it, and take the partial output?
        var block = Uint8List(cipher.blockSize);
        for (var i = 0; i < input.length - offset; i++) {
          block[i] = input[offset + i];
        }
        var outBlock = Uint8List(cipher.blockSize);
        cipher.processBlock(block, 0, outBlock, 0);
        for (var i = 0; i < input.length - offset; i++) {
          output[offset + i] = outBlock[i];
        }
        offset += input.length - offset;
      }
    }
    return output;
  }

  static String _bytesToHex(List<int> bytes) {
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join('');
  }
}
