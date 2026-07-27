import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import 'webvpn_tls_policy.dart';

/// 为原生平台配置受限的 WebVPN 证书兼容策略。
void configureWebVpnCertificatePolicy(Dio dio) {
  final adapter = dio.httpClientAdapter;
  if (adapter is! IOHttpClientAdapter) return;

  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      client.badCertificateCallback = (
        X509Certificate certificate,
        String host,
        int port,
      ) {
        final allowed = WebVpnTlsPolicy.shouldAllowInvalidCertificate(
          certificateHost: host,
          certificatePort: port,
          certificateDer: Uint8List.fromList(certificate.der),
        );
        if (kDebugMode &&
            host == WebVpnTlsPolicy.host &&
            port == WebVpnTlsPolicy.port) {
          debugPrint(
            '[WebVPN] TLS 证书校验失败，${allowed ? '匹配固定公钥并放行' : '未匹配固定公钥并拒绝'}',
          );
        }
        return allowed;
      };
      return client;
    },
  );
}
