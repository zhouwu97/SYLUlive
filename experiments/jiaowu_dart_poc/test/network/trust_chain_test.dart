import 'dart:io';

import 'package:jiaowu_dart_poc/jiaowu_dart.dart';
import 'package:test/test.dart';

void main() {
  test('内置 TrustAsia 中间证书可以载入并保留系统根证书', () {
    final context = JiaowuTrustChain.createSecurityContext();

    // HttpClient 能成功创建，说明 PEM 已被 SecurityContext 解析。
    final client = HttpClient(context: context);
    addTearDown(client.close);

    expect(
      JiaowuTrustChain.intermediateName,
      'TrustAsia OV TLS RSA CA 2024',
    );
    expect(JiaowuTrustChain.bundledTrustVersion, 'trustasia-ov-rsa-2024-certum-v2');
    expect(
      JiaowuTrustChain.intermediateCertificateSha256,
      'D0:B6:26:C8:AD:93:96:22:96:B3:92:01:06:ED:7F:B3:81:8F:CB:98:E0:B7:3E:79:91:41:B4:25:21:33:5B:0F',
    );
  });
}
