import 'dart:convert';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:crypto/crypto.dart';

/// WebVPN 的受限证书兼容策略。
///
/// 仅当系统证书校验失败且服务端公钥与已确认指纹一致时才放行，
/// 不会降低其他域名或端口的 TLS 校验标准。
class WebVpnTlsPolicy {
  static const host = 'webvpn.sylu.edu.cn';
  static const port = 443;

  static const allowedSpkiSha256Pins = <String>[
    'sha256/AMjyEjtjJBu0uaPdog4raWiRXR/aMpSCZh59JH6vImk=',
  ];

  static bool shouldAllowInvalidCertificate({
    required String certificateHost,
    required int certificatePort,
    required Uint8List certificateDer,
    Iterable<String> pins = allowedSpkiSha256Pins,
  }) {
    if (certificateHost != host || certificatePort != port) {
      return false;
    }

    final normalizedPins = _normalizePins(pins);
    if (normalizedPins.isEmpty) return false;

    try {
      final pin = base64Encode(spkiSha256(certificateDer).bytes);
      return normalizedPins.contains(pin);
    } on FormatException {
      return false;
    }
  }

  static Digest spkiSha256(Uint8List certificateDer) {
    return sha256.convert(extractSubjectPublicKeyInfo(certificateDer));
  }

  static Uint8List extractSubjectPublicKeyInfo(Uint8List certificateDer) {
    final parser = ASN1Parser(certificateDer);
    final certificate = parser.nextObject();
    if (certificate is! ASN1Sequence || certificate.elements.isEmpty) {
      throw const FormatException('证书不是有效的 ASN.1 序列');
    }

    final tbsCertificate = certificate.elements.first;
    if (tbsCertificate is! ASN1Sequence) {
      throw const FormatException('证书缺少 TBSCertificate');
    }

    final hasExplicitVersion = tbsCertificate.elements.isNotEmpty &&
        tbsCertificate.elements.first.tag == 0xa0;
    final spkiIndex = hasExplicitVersion ? 6 : 5;
    if (tbsCertificate.elements.length <= spkiIndex) {
      throw const FormatException('证书缺少 SubjectPublicKeyInfo');
    }

    final spki = tbsCertificate.elements[spkiIndex];
    if (spki is! ASN1Sequence) {
      throw const FormatException('SubjectPublicKeyInfo 格式错误');
    }
    return Uint8List.fromList(spki.encodedBytes);
  }

  static Set<String> _normalizePins(Iterable<String> pins) {
    return pins
        .map((pin) => pin.trim())
        .where((pin) => pin.isNotEmpty)
        .map((pin) => pin.startsWith('sha256/') ? pin.substring(7) : pin)
        .toSet();
  }
}
