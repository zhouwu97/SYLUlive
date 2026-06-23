import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/asymmetric/pkcs1.dart';
import 'package:pointycastle/asymmetric/rsa.dart';
import 'package:shenliyuan/features/campus_data/common/campus_data_exception.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_crypto.dart';

void main() {
  group('ErkeCrypto', () {
    late String testPublicKeyBase64;
    late String testPlaintext;

    setUp(() {
      final file = File('test/fixtures/campus_data/crypto_vectors.json');
      final jsonStr = file.readAsStringSync();
      final data = json.decode(jsonStr);

      final vector = data['erke_rsa'];
      testPublicKeyBase64 = vector['public_key_base64'] as String;
      testPlaintext = vector['plaintext'] as String;
    });

    test(
        'encrypts password and can be decrypted by matching private key if we had one',
        () {
      // We don't have the private key for the SYLU live test key in the fixture (it's public only).
      // However, we can verify that encryption succeeds and produces valid Base64 of correct length.
      final encryptedBase64 =
          ErkeCrypto.encryptPassword(testPlaintext, testPublicKeyBase64);

      final encryptedBytes = base64Decode(encryptedBase64);
      expect(encryptedBytes.length, 128); // 1024 bit key = 128 bytes
    });

    test('throws ErkeDecodeException on invalid public key', () {
      expect(
        () => ErkeCrypto.encryptPassword('password', 'invalid_base_64_!!!'),
        throwsA(isA<ErkeDecodeException>()),
      );
    });

    test('supports keys with PEM headers', () {
      final pemKey = '''-----BEGIN PUBLIC KEY-----
$testPublicKeyBase64
-----END PUBLIC KEY-----''';

      final encryptedBase64 = ErkeCrypto.encryptPassword(testPlaintext, pemKey);
      final encryptedBytes = base64Decode(encryptedBase64);
      expect(encryptedBytes.length, 128);
    });
  });
}
