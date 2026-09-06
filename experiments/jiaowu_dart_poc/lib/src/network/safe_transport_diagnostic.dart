import 'dart:io';

import 'package:dio/dio.dart';

/// 可安全展示给用户或附加到排障报告的 transport 摘要。
///
/// 这里只保存请求阶段、Dio 异常类型、底层异常类型、目标 host 和 errno，
/// 明确不复制 headers、Cookie、请求体或响应体。
final class SafeTransportDiagnostic {
  const SafeTransportDiagnostic({
    required this.operation,
    required this.code,
    required this.dioType,
    required this.innerType,
    required this.host,
    this.socketErrorCode,
    this.tlsReason,
    this.tlsDetail,
  });

  factory SafeTransportDiagnostic.fromDioException({
    required DioException error,
    required String operation,
    required String code,
    String? tlsReason,
    String? tlsDetail,
  }) {
    final inner = error.error;
    return SafeTransportDiagnostic(
      operation: operation,
      code: code,
      dioType: error.type.name,
      innerType: inner?.runtimeType.toString() ?? 'none',
      host: error.requestOptions.uri.host,
      socketErrorCode:
          inner is SocketException ? inner.osError?.errorCode : null,
      tlsReason: tlsReason,
      tlsDetail: tlsDetail,
    );
  }

  factory SafeTransportDiagnostic.fromSocketException({
    required SocketException error,
    required String operation,
    required String code,
    String host = '',
    String dioType = 'socket',
  }) {
    return SafeTransportDiagnostic(
      operation: operation,
      code: code,
      dioType: dioType,
      innerType: error.runtimeType.toString(),
      host: host,
      socketErrorCode: error.osError?.errorCode,
    );
  }

  final String operation;
  final String code;
  final String dioType;
  final String innerType;
  final String host;
  final int? socketErrorCode;
  final String? tlsReason;
  final String? tlsDetail;

  /// 只输出白名单字段，供 Probe 状态区域使用。
  String toDisplayString() {
    final lines = <String>[
      code,
      'stage: $operation',
      'dio: $dioType',
      'inner: $innerType',
      'host: ${host.isEmpty ? 'unknown' : host}',
    ];
    if (socketErrorCode != null) {
      lines.add('errno: $socketErrorCode');
    }
    if (tlsReason != null) {
      lines.add('reason: $tlsReason');
    }
    if (tlsDetail != null) {
      lines.add('detail: $tlsDetail');
    }
    return lines.join('\n');
  }

  @override
  String toString() => toDisplayString();
}
