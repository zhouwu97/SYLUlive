import 'dart:convert';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/asymmetric/pkcs1.dart';
import 'package:pointycastle/asymmetric/rsa.dart';
import 'package:shenliyuan/features/campus_data/common/campus_data_exception.dart';

class ErkeCrypto {
  /// Encrypts the user's password using the RSA public key provided by the Erke page.
  /// The key is expected to be a Base64-encoded string (with or without PEM headers).
  /// Uses RSA PKCS#1 v1.5 padding.
  static String encryptPassword(String password, String base64PublicKey) {
    try {
      final publicKey = _parsePublicKey(base64PublicKey);

      final cipher = PKCS1Encoding(RSAEngine());
      cipher.init(
          true, PublicKeyParameter<RSAPublicKey>(publicKey)); // true = encrypt

      final plaintext = utf8.encode(password);
      final ciphertext = cipher.process(Uint8List.fromList(plaintext));

      return base64Encode(ciphertext);
    } catch (e) {
      throw ErkeDecodeException();
    }
  }

  static RSAPublicKey _parsePublicKey(String keyString) {
    // Remove any PEM headers and footers, and all whitespace
    var base64String = keyString
        .replaceAll('-----BEGIN PUBLIC KEY-----', '')
        .replaceAll('-----END PUBLIC KEY-----', '')
        .replaceAll('-----BEGIN RSA PUBLIC KEY-----', '')
        .replaceAll('-----END RSA PUBLIC KEY-----', '')
        .replaceAll(RegExp(r'\s+'), '');

    final keyBytes = base64Decode(base64String);

    // Try parsing as SubjectPublicKeyInfo (X.509)
    try {
      final asn1Parser = ASN1Parser(keyBytes);
      final topLevelSeq = asn1Parser.nextObject() as ASN1Sequence;

      if (topLevelSeq.elements.length == 2 &&
          topLevelSeq.elements[0] is ASN1Sequence &&
          topLevelSeq.elements[1] is ASN1BitString) {
        // It's X.509
        final bitString = topLevelSeq.elements[1] as ASN1BitString;
        final innerAsn1Parser = ASN1Parser(bitString.contentBytes());
        final rsaSeq = innerAsn1Parser.nextObject() as ASN1Sequence;

        final modulus = (rsaSeq.elements[0] as ASN1Integer).valueAsBigInteger;
        final exponent = (rsaSeq.elements[1] as ASN1Integer).valueAsBigInteger;

        return RSAPublicKey(modulus, exponent);
      }
    } catch (_) {
      // Ignore and fallback
    }

    // Try parsing as PKCS#1 RSA Public Key directly
    try {
      final asn1Parser = ASN1Parser(keyBytes);
      final topLevelSeq = asn1Parser.nextObject() as ASN1Sequence;

      final modulus = (topLevelSeq.elements[0] as ASN1Integer).valueAsBigInteger;
      final exponent = (topLevelSeq.elements[1] as ASN1Integer).valueAsBigInteger;

      return RSAPublicKey(modulus, exponent);
    } catch (_) {
      // Ignore
    }

    throw ArgumentError('Invalid RSA public key format');
  }
}
