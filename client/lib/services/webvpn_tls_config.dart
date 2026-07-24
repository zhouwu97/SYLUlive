import 'package:dio/dio.dart';

/// Web 平台没有 dart:io 的 HttpClient，保留系统默认 TLS 校验。
void configureWebVpnCertificatePolicy(Dio dio) {}
