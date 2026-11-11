import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/ecc/ecc_fp.dart' as fp;
import 'package:pointycastle/export.dart';

/// 「扫码同步到网页」的端到端加密。
///
/// 网页把一次性 P-256 公钥放在二维码里；App 生成自己的一次性密钥，
/// 用 ECDH 得到共享秘密，经 HKDF-SHA256 派生 AES-256-GCM 密钥后加密资料。
/// 服务器只中转密文，拿不到网页私钥，因此无法解密。
///
/// 协议常量、HKDF 盐与 GCM 附加数据必须与网页 `academic-transfer.ts` 逐字一致；
/// 两端测试共用同一组固定向量。
const String academicTransferProtocol = 'sylulive-academic-transfer-v1';

class AcademicTransferEnvelope {
  const AcademicTransferEnvelope({
    required this.appPublicKey,
    required this.nonce,
    required this.ciphertext,
  });

  final String appPublicKey;
  final String nonce;
  final String ciphertext;

  Map<String, String> toJson() => <String, String>{
        'app_public_key': appPublicKey,
        'nonce': nonce,
        'ciphertext': ciphertext,
      };
}

class AcademicTransferCryptoException implements Exception {
  const AcademicTransferCryptoException(this.message);
  final String message;
  @override
  String toString() => message;
}

final ECDomainParameters _curve = ECDomainParameters('prime256v1');

String academicTransferBase64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List academicTransferDecodeBase64Url(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]*$').hasMatch(value)) {
    throw const FormatException('base64url 编码不正确');
  }
  return base64Url.decode(base64Url.normalize(value));
}

/// 用网页二维码中的公钥加密资料。`appPrivateKey`、`nonce` 仅供测试固定向量使用。
AcademicTransferEnvelope encryptAcademicTransfer({
  required String webPublicKey,
  required String sessionId,
  required List<int> plaintext,
  BigInt? appPrivateKey,
  Uint8List? nonce,
}) {
  final ECPublicKey webKey;
  try {
    final raw = academicTransferDecodeBase64Url(webPublicKey);
    if (raw.length != 65 || raw.first != 0x04) {
      throw const FormatException('公钥长度不正确');
    }
    final point = _curve.curve.decodePoint(raw);
    if (point == null || point.isInfinity || !_onCurve(point)) {
      throw const FormatException('公钥不在曲线上');
    }
    webKey = ECPublicKey(point, _curve);
  } catch (_) {
    throw const AcademicTransferCryptoException('二维码中的加密信息不完整，请在网页重新生成二维码');
  }

  final random = _secureRandom();
  final ECPrivateKey appPrivate;
  final ECPublicKey appPublic;
  if (appPrivateKey != null) {
    appPrivate = ECPrivateKey(appPrivateKey, _curve);
    appPublic = ECPublicKey(_curve.G * appPrivateKey, _curve);
  } else {
    final generator = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(_curve), random));
    final pair = generator.generateKeyPair();
    appPrivate = pair.privateKey as ECPrivateKey;
    appPublic = pair.publicKey as ECPublicKey;
  }

  final agreement = ECDHBasicAgreement()..init(appPrivate);
  final shared = _fixedLength(agreement.calculateAgreement(webKey), 32);
  final key = Uint8List(32);
  HKDFKeyDerivator(SHA256Digest())
    ..init(HkdfParameters(
      shared,
      32,
      Uint8List.fromList(utf8.encode(sessionId)),
      Uint8List.fromList(utf8.encode(academicTransferProtocol)),
    ))
    ..deriveKey(null, 0, key, 0);

  final iv = nonce ?? random.nextBytes(12);
  if (iv.length != 12) throw ArgumentError.value(iv.length, 'nonce');
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(
        KeyParameter(key),
        128,
        iv,
        Uint8List.fromList(utf8.encode('$academicTransferProtocol|$sessionId')),
      ),
    );
  final ciphertext = cipher.process(Uint8List.fromList(plaintext));

  return AcademicTransferEnvelope(
    appPublicKey: academicTransferBase64Url(appPublic.Q!.getEncoded(false)),
    nonce: academicTransferBase64Url(iv),
    ciphertext: academicTransferBase64Url(ciphertext),
  );
}

SecureRandom _secureRandom() {
  final seed = Random.secure();
  return FortunaRandom()
    ..seed(KeyParameter(
        Uint8List.fromList(List<int>.generate(32, (_) => seed.nextInt(256)))));
}

/// pointycastle 解码时不检查曲线方程；不在曲线上的点会让 ECDH 结果不可信，必须拒绝。
bool _onCurve(ECPoint point) {
  final curve = _curve.curve as fp.ECCurve;
  final p = curve.q!;
  final x = point.x!.toBigInteger()!, y = point.y!.toBigInteger()!;
  if (x >= p || y >= p || x.isNegative || y.isNegative) return false;
  final a = curve.a!.toBigInteger()!, b = curve.b!.toBigInteger()!;
  return (y * y - (x * x * x + a * x + b)) % p == BigInt.zero;
}

/// ECDH 结果按大端补齐到固定长度，与 WebCrypto deriveBits 的输出一致。
Uint8List _fixedLength(BigInt value, int length) {
  final bytes = Uint8List(length);
  var remaining = value;
  for (var index = length - 1; index >= 0; index--) {
    bytes[index] = (remaining & BigInt.from(0xff)).toInt();
    remaining = remaining >> 8;
  }
  return bytes;
}
