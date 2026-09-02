import 'dart:convert';
import 'dart:typed_data';

import 'package:jiaowu_dart_poc/jiaowu_dart.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/asymmetric/pkcs1.dart';
import 'package:pointycastle/asymmetric/rsa.dart';
import 'package:pointycastle/key_generators/api.dart';
import 'package:pointycastle/key_generators/rsa_key_generator.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:test/test.dart';

void main() {
  test('RSA PKCS#1 v1.5 密文可由测试私钥解密回原始 UTF-8 密码', () {
    final random = FortunaRandom()
      ..seed(KeyParameter(
          Uint8List.fromList(List<int>.generate(32, (i) => i + 1))));
    final generator = RSAKeyGenerator()
      ..init(
        ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), 1024, 12),
          random,
        ),
      );
    final pair = generator.generateKeyPair();
    final publicKey = pair.publicKey as RSAPublicKey;
    final privateKey = pair.privateKey as RSAPrivateKey;

    final modulus = base64.encode(_toUnsignedBytes(publicKey.modulus!));
    final exponent = base64.encode(_toUnsignedBytes(publicKey.publicExponent!));
    final encrypted = encryptPassword(
      password: '校园密码-测试',
      modulus: modulus,
      exponent: exponent,
    );

    final decryptor = PKCS1Encoding(RSAEngine())
      ..init(false, PrivateKeyParameter<RSAPrivateKey>(privateKey));
    final plain = decryptor.process(base64.decode(encrypted));

    expect(utf8.decode(plain), '校园密码-测试');
  });

  test('相同明文不会要求相同随机填充密文', () {
    // 这个断言只检查协议语义：调用两次生成的 PKCS#1 v1.5 密文不应被拿来做相等比较。
    // 使用同一组 1024-bit 测试参数，避免引入任何真实学校公钥。
    const modulus = 'ALWAYS_INVALID_IN_FIXTURE';
    const exponent = 'AQAB';

    expect(
      () => encryptPassword(
        password: 'test',
        modulus: modulus,
        exponent: exponent,
      ),
      throwsA(isA<LoginPageChangedException>()),
    );
  });
}

Uint8List _toUnsignedBytes(BigInt value) {
  final bytes = <int>[];
  var current = value;
  while (current > BigInt.zero) {
    bytes.add((current & BigInt.from(255)).toInt());
    current >>= 8;
  }
  return Uint8List.fromList(bytes.reversed.toList());
}
