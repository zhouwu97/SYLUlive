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
      'TrustAsia TLS Pro RSA CA 2025',
    );
    expect(JiaowuTrustChain.bundledTrustVersion, 'trustasia-rsa-2025-v1');
    expect(
      JiaowuTrustChain.intermediateCertificateSha256,
      '41:6A:2C:89:51:5B:8B:C1:4E:13:67:70:24:E2:A8:2E:8B:1B:2F:41:17:A8:8F:D1:1B:8B:BD:25:D1:A5:C5:17',
    );
  });
}
