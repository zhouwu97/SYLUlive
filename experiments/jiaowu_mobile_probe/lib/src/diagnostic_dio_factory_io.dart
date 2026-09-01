import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

Dio createDiagnosticDio({required bool insecureTls}) {
  final dio = Dio();
  if (!insecureTls) return dio;
  if (!kDebugMode) {
    throw StateError('insecure TLS 诊断只允许 Debug 构建');
  }

  final allowedHost = Uri.parse(JiaowuEndpoints.defaultBaseUrl).host;
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      client.badCertificateCallback = (_, requestHost, _) {
        return requestHost == allowedHost;
      };
      return client;
    },
  );
  return dio;
}
