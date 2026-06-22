import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/campus_data/common/cas_crypto.dart';

void main() {
  group('CasCrypto', () {
    test('encryptPassword matches Python crypto vectors', () {
      final file = File('test/fixtures/campus_data/crypto_vectors.json');
      final jsonStr = file.readAsStringSync();
      final data = json.decode(jsonStr);

      final vector = data['cas_login'];
      final salt = vector['salt'] as String;
      final prefix64 = vector['prefix_64'] as String;
      final password = vector['password'] as String;
      final iv16 = vector['iv_16'] as String;
      final expectedBase64 = vector['expected_base64'] as String;

      final encrypted = CasCrypto.encryptPassword(
        salt,
        password,
        randomPrefix: prefix64,
        ivOverride: utf8.encode(iv16),
      );

      expect(encrypted, expectedBase64);
    });

    test('generates different random prefixes and ivs', () {
      final salt = '1234567890abcdef'; // Must be 16 bytes for AES key
      final pw = 'password123';
      
      final e1 = CasCrypto.encryptPassword(salt, pw);
      final e2 = CasCrypto.encryptPassword(salt, pw);
      
      expect(e1, isNot(equals(e2)));
    });
  });
}
