import 'dart:io';

import 'package:dio/dio.dart';

import '../error/jiaowu_exception.dart';
import 'safe_transport_diagnostic.dart';

/// 将 Dio/Socket 层异常统一转换为可行动、且不会泄漏请求内容的教务异常。
abstract final class TransportErrorMapper {
  static JiaowuException map(DioException error, String operation) {
    final code = _codeFor(error);
    final diagnostic = SafeTransportDiagnostic.fromDioException(
      error: error,
      operation: operation,
      code: code,
    );

    if (code == 'REQUEST_TIMEOUT') {
      return RequestTimeoutException(
        message: '$operation超时',
        cause: error,
        diagnostic: diagnostic,
      );
    }

    return NetworkException(
      message: _messageFor(code, operation),
      code: code,
      cause: error,
      diagnostic: diagnostic,
    );
  }

  static String _codeFor(DioException error) {
    if (isTimeout(error)) return 'REQUEST_TIMEOUT';

    final inner = error.error;
    if (error.type == DioExceptionType.badCertificate ||
        inner is HandshakeException ||
        _looksLikeTlsFailure(error)) {
      return 'TLS_HANDSHAKE_FAILED';
    }

    final text = _transportText(error);
    if (_containsAny(text, [
      'failed host lookup',
      'nodename nor servname provided',
      'name or service not known',
      'no address associated with hostname',
      'temporary failure in name resolution',
    ])) {
      return 'DNS_LOOKUP_FAILED';
    }
    if (_containsAny(text, [
      'network is unreachable',
      'no route to host',
      'network unreachable',
    ])) {
      return 'NETWORK_UNREACHABLE';
    }
    if (_containsAny(text, ['connection refused', 'actively refused'])) {
      return 'CONNECTION_REFUSED';
    }
    return 'CONNECTION_FAILED';
  }

  static String _messageFor(String code, String operation) {
    return switch (code) {
      'TLS_HANDSHAKE_FAILED' => '$operation时 TLS 握手失败',
      'DNS_LOOKUP_FAILED' => '无法解析教务服务器地址',
      'NETWORK_UNREACHABLE' => '当前网络无法连接教务服务器',
      'CONNECTION_REFUSED' => '教务服务器拒绝连接',
      _ => '$operation失败，请检查网络连接',
    };
  }

  static bool isTimeout(DioException error) {
    return error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout;
  }

  static bool _looksLikeTlsFailure(DioException error) {
    final text = _transportText(error);
    return _containsAny(text, [
      'certificate_verify_failed',
      'certificate verify failed',
      'hostname mismatch',
      'handshake failure',
      'handshake error',
      'ssl_error',
      'tls handshake',
    ]);
  }

  static String _transportText(DioException error) {
    final inner = error.error;
    final innerText = inner is SocketException ? inner.message : inner;
    return '${error.message ?? ''} ${innerText ?? ''}'.toLowerCase();
  }

  static bool _containsAny(String text, Iterable<String> needles) {
    return needles.any(text.contains);
  }
}
