import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

void configureDebugWebVpnCertificateDiagnostics(Dio dio) {
  if (!kDebugMode) return;

  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      client.badCertificateCallback = (
        X509Certificate certificate,
        String host,
        int port,
      ) {
        return host == 'webvpn.sylu.edu.cn' && port == 443;
      };
      return client;
    },
  );
}
