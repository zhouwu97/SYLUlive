/// 学校登录接口返回的 Base64 编码 RSA 公钥参数。
final class RsaPublicKeyData {
  const RsaPublicKeyData({required this.modulus, required this.exponent});

  final String modulus;
  final String exponent;
}
