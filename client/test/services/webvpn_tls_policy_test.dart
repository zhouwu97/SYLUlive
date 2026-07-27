import 'dart:convert';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/webvpn_tls_policy.dart';

void main() {
  group('WebVpnTlsPolicy', () {
    late Uint8List certificateDer;
    late String spkiPin;

    setUp(() {
      final spkiDer = base64Decode(
        'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC3hzrH91c0OKgtaSB7GWGfDuUJsMrtiYThDXtJdrCr7exKt2fmIZngoFk71Dv/BPVQCHSuohNNvEV9VVDFSBhsP9xKEDAM4/2Lv+wlzN9CuZtLpV3Elo8VacjwMHcjTRmTchRBmijQzZRFrA2LM+qsH3U5tRM1uJFbfRMkBq24AwIDAQAB',
      );
      certificateDer = _fakeCertificateDer(spkiDer);
      spkiPin = base64Encode(sha256.convert(spkiDer).bytes);
    });

    test('仅对固定主机、端口和公钥指纹放行异常证书', () {
      expect(
        WebVpnTlsPolicy.shouldAllowInvalidCertificate(
          certificateHost: WebVpnTlsPolicy.host,
          certificatePort: WebVpnTlsPolicy.port,
          certificateDer: certificateDer,
          pins: ['sha256/$spkiPin'],
        ),
        isTrue,
      );
      expect(
        WebVpnTlsPolicy.shouldAllowInvalidCertificate(
          certificateHost: 'example.com',
          certificatePort: WebVpnTlsPolicy.port,
          certificateDer: certificateDer,
          pins: ['sha256/$spkiPin'],
        ),
        isFalse,
      );
      expect(
        WebVpnTlsPolicy.shouldAllowInvalidCertificate(
          certificateHost: WebVpnTlsPolicy.host,
          certificatePort: 8443,
          certificateDer: certificateDer,
          pins: ['sha256/$spkiPin'],
        ),
        isFalse,
      );
      expect(
        WebVpnTlsPolicy.shouldAllowInvalidCertificate(
          certificateHost: WebVpnTlsPolicy.host,
          certificatePort: WebVpnTlsPolicy.port,
          certificateDer: certificateDer,
          pins: const ['sha256/not-a-match'],
        ),
        isFalse,
      );
    });

    test('内置指纹是已核实的学校 WebVPN 公钥指纹', () {
      expect(
        WebVpnTlsPolicy.allowedSpkiSha256Pins,
        contains('sha256/AMjyEjtjJBu0uaPdog4raWiRXR/aMpSCZh59JH6vImk='),
      );
    });
  });
}

Uint8List _fakeCertificateDer(Uint8List spkiDer) {
  final tbs = ASN1Sequence()
    ..add(ASN1Integer.fromInt(1))
    ..add(_algorithmIdentifier())
    ..add(ASN1Sequence())
    ..add(ASN1Sequence())
    ..add(ASN1Sequence())
    ..add(ASN1Sequence.fromBytes(spkiDer));
  final certificate = ASN1Sequence()
    ..add(tbs)
    ..add(_algorithmIdentifier())
    ..add(ASN1BitString([0]));
  return certificate.encodedBytes;
}

ASN1Sequence _algorithmIdentifier() {
  return ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.113549.1.1.11'))
    ..add(ASN1Null());
}
