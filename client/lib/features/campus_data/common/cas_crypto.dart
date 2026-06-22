import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart';

class CasCrypto {
  /// Encrypts the password for CAS login using AES-CBC.
  /// The plaintext is composed of a 64-character random prefix concatenated with the password.
  /// [salt] is dynamically obtained from the page (pwdEncryptSalt).
  /// [password] is the user's plaintext password.
  /// [randomPrefix] allows injecting a fixed 64-char string for testing, otherwise a random one is generated.
  /// [ivOverride] allows injecting a fixed 16-byte IV for testing, otherwise a random one is generated.
  static String encryptPassword(
    String salt,
    String password, {
    String? randomPrefix,
    List<int>? ivOverride,
  }) {
    final prefix = randomPrefix ?? _generateRandomString(64);
    final plaintext = prefix + password;
    final keyBytes = utf8.encode(salt);

    // IV must be 16 bytes
    final ivBytes = ivOverride ?? utf8.encode(_generateRandomString(16));

    final key = Key(Uint8List.fromList(keyBytes));
    final iv = IV(Uint8List.fromList(ivBytes));

    final encrypter = Encrypter(AES(key, mode: AESMode.cbc, padding: 'PKCS7'));

    final encrypted = encrypter.encrypt(plaintext, iv: iv);

    // Return base64 representation
    return encrypted.base64;
  }

  static const String _chars =
      'ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678';

  static String _generateRandomString(int length) {
    final rand = Random.secure();
    return List.generate(length, (index) => _chars[rand.nextInt(_chars.length)])
        .join();
  }
}
