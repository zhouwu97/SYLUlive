import 'package:dio/dio.dart';

Dio createDiagnosticDio({required bool insecureTls}) {
  if (insecureTls) {
    throw UnsupportedError('当前平台不支持 Debug insecure TLS 诊断');
  }
  return Dio();
}
