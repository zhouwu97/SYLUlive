import 'dart:convert';
import 'dart:io';

/// 教务站点当前部署的 TrustAsia 中间证书。
///
/// 服务端没有下发该中间证书，Android 系统证书链构建会因此失败。
/// 这里只补充这一张固定证书，仍保留系统根证书和主机名校验，不使用
/// badCertificateCallback，也不接受任意自签名证书。
abstract final class JiaowuTrustChain {
  static const intermediateName = 'TrustAsia TLS Pro RSA CA 2025';
  static const bundledTrustVersion = 'trustasia-rsa-2025-v1';
  static const intermediateCertificateSha256 =
      '41:6A:2C:89:51:5B:8B:C1:4E:13:67:70:24:E2:A8:2E:8B:1B:2F:41:17:A8:8F:D1:1B:8B:BD:25:D1:A5:C5:17';

  static const _intermediateCertificatePem = '''-----BEGIN CERTIFICATE-----
MIIFmzCCBIOgAwIBAgIQA5tCre0AuFXvGGA4B3eYFjANBgkqhkiG9w0BAQsFADBh
MQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3
d3cuZGlnaWNlcnQuY29tMSAwHgYDVQQDExdEaWdpQ2VydCBHbG9iYWwgUm9vdCBH
MjAeFw0yNTAxMDgwMDAwMDBaFw0zNTAxMDcyMzU5NTlaMFwxCzAJBgNVBAYTAkNO
MSUwIwYDVQQKExxUcnVzdEFzaWEgVGVjaG5vbG9naWVzLCBJbmMuMSYwJAYDVQQD
Ex1UcnVzdEFzaWEgVExTIFBybyBSU0EgQ0EgMjAyNTCCAiIwDQYJKoZIhvcNAQEB
BQADggIPADCCAgoCggIBANhLewv27ZdeKbLuwp/sLiMfNd1FSmZmBRiT91cdW2u0
VyUW7nU1EkPuBF5Lyf77I4TCq1vDqkW4RrCxho/UcGdcJHmTAqs+tvKDX4yt2MoJ
J+AJj8sSsT755PKMi1Ey3p+Q84dC8f3jI2ZocyfLrPKuBnTbVhPyOV7OksNnwfeR
tdXMivkx1sLeGmgDIxyrwsp/BbYN4dzyoC8DI2yGtJ0Jq/mtl/YJpx69LzWoH5vb
9NkZuVA5ZwX6TT3m0M2QoptF75CICgqAs2x+ivdVTLIdpdVZq1bsoGRfPhGc6BRX
4bbBqOrKWIwejdossXn+nskbXmNUb85iAjC8t57QBEIGtKWBWU3ZpmBdhHNwHl9Q
h2OYW3ux2mAYoZAAYmcthneKtn96H4lhinTepuOVyp8gSxzZT/EPl4Grb/q0+pf+
H38vhCQuPzS+d6Cr8LSCZMKzd+B++rTzG9HpHrBPfRo8CRFc4sGDwoVf2vUNKw9V
BHatNV8Q9+6mpKJY5/esdAujuh50m0zlX7IJsfcajEhBkG/7OCZWpl78wjVANMUo
cxaAUSWzXJVmigHygaDhFDugKiFhNF5yZlTyTwO9aEf2ery4SWBMyEDLPTlWCH1T
4Zn5glRrx+AFk0sO0ltHhNjH6g2n744Ia+SDl3DpqeW06NDjNeGvjKk2nEmZ6EUx
AgMBAAGjggFSMIIBTjASBgNVHRMBAf8ECDAGAQH/AgEAMB0GA1UdDgQWBBR/ndoa
gHko6CypCtaN3DJP7nSdeTAfBgNVHSMEGDAWgBROIlQgGJXm427mD/r6uRLtBheP
OTAOBgNVHQ8BAf8EBAMCAYYwHQYDVR0lBBYwFAYIKwYBBQUHAwEGCCsGAQUFBwMC
MHQGCCsGAQUFBwEBBGgwZjAjBggrBgEFBQcwAYYXaHR0cDovL29jc3AuZGlnaWNl
cnQuY24wPwYIKwYBBQUHMAKGM2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNuL0Rp
Z2lDZXJ0R2xvYmFsUm9vdEcyLmNydDBABgNVHR8EOTA3MDWgM6Axhi9odHRwOi8v
Y3JsLmRpZ2ljZXJ0LmNuL0RpZ2lDZXJ0R2xvYmFsUm9vdEcyLmNybDARBgNVHSAE
CjAIMAYGBFUdIAAwDQYJKoZIhvcNAQELBQADggEBADNxco0So9rb1WwbElGu8mpR
Lb1BD/KeH93fwvrv43d6XESEIHOkk/kTQr6TvAZkKzYoM5zi89DPkMjDrbwpnXYN
1nZITva3cB5mq5QTpoV7Ayit2fxVnBNujsFQhX2Rix1m7vEBI/zAHMcnGl+6f1Ux
k3N9reStXWN3sNQZkFwolxeUoo3GmBU4REoMIhPzHslfAGELAOR1lqDMe82Pxjow
YvBy1Ta6gKwR2eBMdsi9lC3V9eJYDxeDT/JSR+8a/8gYbDf0qf/r30+iIcvIRfLY
ABxd0Cldpo0bt5Gh03s1b5jWPDIQ1feLRFP9RaAdt3Owt+dRQtuY3kloDbYIUEI=
-----END CERTIFICATE-----''';

  /// 创建保留系统根证书、并额外信任指定中间证书的 TLS 上下文。
  static SecurityContext createSecurityContext() {
    final context = SecurityContext(withTrustedRoots: true);
    context
        .setTrustedCertificatesBytes(utf8.encode(_intermediateCertificatePem));
    return context;
  }

  /// Dio 的 IO 适配器按请求创建 HttpClient 时使用的工厂。
  ///
  /// 非教务域名不加载这张额外证书，避免自定义 baseUrl 意外扩大信任范围。
  static HttpClient createHttpClient({bool useBundledIntermediate = true}) {
    if (!useBundledIntermediate) return HttpClient();
    return HttpClient(context: createSecurityContext());
  }
}
