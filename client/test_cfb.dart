import 'package:pointycastle/export.dart';
import 'dart:convert';
import 'dart:typed_data';

void main() { 
  final keyBytes = utf8.encode('wrdvpnisthebest!') as Uint8List;
  final ivBytes = utf8.encode('wrdvpnisthebest!') as Uint8List;
  final plainBytes = utf8.encode('xg.sylu.edu.cn') as Uint8List;

  final cipher = CFBBlockCipher(AESEngine(), 16);
  cipher.init(true, ParametersWithIV(KeyParameter(keyBytes), ivBytes));

  final cipherBytes = Uint8List(plainBytes.length);
  int offset = 0;
  while (offset < plainBytes.length) {
    final block = Uint8List(16);
    final remaining = plainBytes.length - offset;
    final chunkSize = remaining < 16 ? remaining : 16;
    block.setRange(0, chunkSize, plainBytes.skip(offset).take(chunkSize));
    
    final outBlock = Uint8List(16);
    cipher.processBlock(block, 0, outBlock, 0);
    cipherBytes.setRange(offset, offset + chunkSize, outBlock.take(chunkSize));
    offset += chunkSize;
  }

  final hexStr = cipherBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  print("Hex: " + hexStr);
}
