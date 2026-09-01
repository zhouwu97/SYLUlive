import 'dart:io';

import 'package:dio/dio.dart';

import '../auth/csrf_parser.dart';
import '../core/jiaowu_endpoints.dart';
import '../core/jiaowu_headers.dart';
import '../error/jiaowu_exception.dart';
import 'safe_transport_diagnostic.dart';
import 'transport_error_mapper.dart';

/// 不需要账号的教务网络探针：DNS → HTTPS → 登录页/CSRF。
final class JiaowuNetworkProbe {
  JiaowuNetworkProbe({
    required Dio dio,
    String baseUrl = JiaowuEndpoints.defaultBaseUrl,
    Duration timeout = const Duration(seconds: 12),
  })  : _dio = dio,
        _baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), ''),
        _timeout = timeout;

  final Dio _dio;
  final String _baseUrl;
  final Duration _timeout;

  String get host => Uri.parse(_baseUrl).host;

  Future<JiaowuNetworkProbeResult> run() async {
    List<InternetAddress> addresses;
    try {
      addresses = await InternetAddress.lookup(host);
    } on SocketException catch (error) {
      final mapped = NetworkException(
        message: '无法解析教务服务器地址',
        code: 'DNS_LOOKUP_FAILED',
        cause: error,
        diagnostic: SafeTransportDiagnostic.fromSocketException(
          error: error,
          operation: 'DNS',
          code: 'DNS_LOOKUP_FAILED',
          host: host,
          dioType: 'dns',
        ),
      );
      return JiaowuNetworkProbeResult(
        dnsSucceeded: false,
        ipv4Count: 0,
        ipv6Count: 0,
        error: mapped,
      );
    }
    if (addresses.isEmpty) {
      final error = NetworkException(
        message: '无法解析教务服务器地址',
        code: 'DNS_LOOKUP_FAILED',
        diagnostic: SafeTransportDiagnostic(
          operation: 'DNS',
          code: 'DNS_LOOKUP_FAILED',
          dioType: 'dns',
          innerType: 'none',
          host: host,
        ),
      );
      return JiaowuNetworkProbeResult(
        dnsSucceeded: false,
        ipv4Count: 0,
        ipv6Count: 0,
        error: error,
      );
    }

    final ipv4Count = addresses
        .where((address) => address.type == InternetAddressType.IPv4)
        .length;
    final ipv6Count = addresses
        .where((address) => address.type == InternetAddressType.IPv6)
        .length;

    try {
      final response = await _dio.get<String>(
        '$_baseUrl${JiaowuEndpoints.loginPage}',
        options: Options(
          headers: JiaowuHeaders.loginPage,
          responseType: ResponseType.plain,
          followRedirects: false,
          validateStatus: (status) =>
              status != null && status >= 200 && status < 600,
          connectTimeout: _timeout,
          receiveTimeout: _timeout,
          sendTimeout: _timeout,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status != 200) {
        return JiaowuNetworkProbeResult(
          dnsSucceeded: true,
          ipv4Count: ipv4Count,
          ipv6Count: ipv6Count,
          httpsSucceeded: true,
          httpStatus: status,
          error: NetworkException(
            message: '教务诊断返回状态码 $status',
            code: 'DIAGNOSTIC_HTTP_STATUS',
          ),
        );
      }

      try {
        CsrfParser.parse(response.data ?? '');
        return JiaowuNetworkProbeResult(
          dnsSucceeded: true,
          ipv4Count: ipv4Count,
          ipv6Count: ipv6Count,
          httpsSucceeded: true,
          httpStatus: status,
          csrfSucceeded: true,
        );
      } on JiaowuException catch (error) {
        return JiaowuNetworkProbeResult(
          dnsSucceeded: true,
          ipv4Count: ipv4Count,
          ipv6Count: ipv6Count,
          httpsSucceeded: true,
          httpStatus: status,
          error: error,
        );
      }
    } on DioException catch (error) {
      final mapped = TransportErrorMapper.map(error, 'HTTPS 诊断');
      return JiaowuNetworkProbeResult(
        dnsSucceeded: true,
        ipv4Count: ipv4Count,
        ipv6Count: ipv6Count,
        error: mapped,
      );
    } on SocketException catch (error) {
      final mapped = NetworkException(
        message: 'HTTPS 诊断失败，请检查网络连接',
        code: 'CONNECTION_FAILED',
        cause: error,
        diagnostic: SafeTransportDiagnostic.fromSocketException(
          error: error,
          operation: 'HTTPS 诊断',
          code: 'CONNECTION_FAILED',
          host: host,
        ),
      );
      return JiaowuNetworkProbeResult(
        dnsSucceeded: true,
        ipv4Count: ipv4Count,
        ipv6Count: ipv6Count,
        error: mapped,
      );
    }
  }
}

/// 网络探针结果只保留诊断所需的状态，不保留响应内容。
final class JiaowuNetworkProbeResult {
  const JiaowuNetworkProbeResult({
    required this.dnsSucceeded,
    required this.ipv4Count,
    required this.ipv6Count,
    this.httpsSucceeded = false,
    this.httpStatus,
    this.csrfSucceeded = false,
    this.error,
  });

  final bool dnsSucceeded;
  final int ipv4Count;
  final int ipv6Count;
  final bool httpsSucceeded;
  final int? httpStatus;
  final bool csrfSucceeded;
  final JiaowuException? error;

  bool get succeeded => dnsSucceeded && httpsSucceeded && csrfSucceeded;
}
