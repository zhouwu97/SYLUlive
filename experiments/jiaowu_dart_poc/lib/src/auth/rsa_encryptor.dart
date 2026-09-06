import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/asymmetric/pkcs1.dart';
import 'package:pointycastle/asymmetric/rsa.dart';

import '../error/jiaowu_exception.dart';
import '../model/rsa_public_key.dart';

/// 使用学校协议要求的 RSA PKCS#1 v1.5 加密密码。
abstract final class RsaEncryptor {
  static String encryptPassword({
    required String password,
    required String modulus,
    required String exponent,
  }) {
    try {
      final n = _decodePositiveBigInt(modulus);
      final e = _decodePositiveBigInt(exponent);
      final cipher = PKCS1Encoding(RSAEngine())
        ..init(
          true,
          PublicKeyParameter<RSAPublicKey>(RSAPublicKey(n, e)),
        );
      final encrypted = cipher.process(
        Uint8List.fromList(utf8.encode(password)),
      );
      return base64.encode(encrypted);
    } on FormatException catch (error) {
      throw LoginPageChangedException(
        message: '教务登录公钥格式错误，请稍后重试或联系管理员',
        cause: error,
      );
    } on ArgumentError catch (error) {
      throw LoginPageChangedException(
        message: '教务密码加密失败，请稍后重试',
        cause: error,
      );
    }
  }

  static String encryptWithKey({
    required String password,
    required RsaPublicKeyData key,
  }) {
    return encryptPassword(
      password: password,
      modulus: key.modulus,
      exponent: key.exponent,
    );
  }

  static BigInt _decodePositiveBigInt(String encoded) {
    final bytes = base64.decode(encoded);
    if (bytes.isEmpty) throw const FormatException('empty RSA component');

    var value = BigInt.zero;
    for (final byte in bytes) {
      value = (value << 8) | BigInt.from(byte);
    }
    if (value <= BigInt.zero) throw const FormatException('zero RSA component');
    return value;
  }
}

/// 与需求文档中的函数名保持一致，便于后续移植到 Flutter。
String encryptPassword({
  required String password,
  required String modulus,
  required String exponent,
}) {
  return RsaEncryptor.encryptPassword(
    password: password,
    modulus: modulus,
    exponent: exponent,
  );
}
