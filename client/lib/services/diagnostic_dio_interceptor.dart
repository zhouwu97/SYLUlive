import 'dart:async';

import 'package:dio/dio.dart';

import 'diagnostic_log_service.dart';

typedef DiagnosticNetworkWriter = Future<void> Function(
  DiagnosticNetworkEvent event,
);

class DiagnosticNetworkEvent {
  const DiagnosticNetworkEvent({
    required this.result,
    required this.method,
    required this.route,
    required this.durationMs,
    required this.dioType,
    required this.retryCount,
    required this.requestId,
    this.httpStatus,
  });

  final String result;
  final String method;
  final String route;
  final int durationMs;
  final int? httpStatus;
  final String dioType;
  final int retryCount;
  final String requestId;

  @override
  String toString() =>
      'DiagnosticNetworkEvent($result $method $route $httpStatus $dioType $requestId)';
}

class DiagnosticDioInterceptor extends Interceptor {
  DiagnosticDioInterceptor({
    DiagnosticNetworkWriter? writer,
    this.slowRequestThreshold = const Duration(seconds: 2),
  }) : _writer = writer ?? _writeNetworkDiagnostic;

  static const startedAtKey = 'diagnostic_started_at_ms';
  static const retryCountKey = 'diagnostic_retry_count';

  final DiagnosticNetworkWriter _writer;
  final Duration slowRequestThreshold;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[startedAtKey] = DateTime.now().millisecondsSinceEpoch;
    super.onRequest(options, handler);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final durationMs = _durationMs(response.requestOptions);
    if (durationMs >= slowRequestThreshold.inMilliseconds) {
      _record(
        DiagnosticNetworkEvent(
          result: 'slow',
          method: response.requestOptions.method.toUpperCase(),
          route: normalizeDiagnosticRoute(response.requestOptions.uri.path),
          durationMs: durationMs,
          httpStatus: response.statusCode,
          dioType: '',
          retryCount: _retryCount(response.requestOptions),
          requestId: _requestId(response.requestOptions),
        ),
      );
    }
    super.onResponse(response, handler);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _record(
      DiagnosticNetworkEvent(
        result: 'failure',
        method: err.requestOptions.method.toUpperCase(),
        route: normalizeDiagnosticRoute(err.requestOptions.uri.path),
        durationMs: _durationMs(err.requestOptions),
        httpStatus: err.response?.statusCode,
        dioType: err.type.name,
        retryCount: _retryCount(err.requestOptions),
        requestId: _requestId(err.requestOptions),
      ),
    );
    super.onError(err, handler);
  }

  void _record(DiagnosticNetworkEvent event) {
    unawaited(_writer(event).catchError((_) {}));
  }

  int _durationMs(RequestOptions options) {
    final startedAt = options.extra[startedAtKey];
    if (startedAt is! int) return 0;
    return (DateTime.now().millisecondsSinceEpoch - startedAt)
        .clamp(0, 1 << 31);
  }

  int _retryCount(RequestOptions options) {
    final value = options.extra[retryCountKey];
    return value is num ? value.toInt().clamp(0, 100) : 0;
  }

  String _requestId(RequestOptions options) {
    return options.headers['X-Request-ID']?.toString() ?? '';
  }
}

String normalizeDiagnosticRoute(String rawPath) {
  var path = rawPath.split('?').first;
  path = path.replaceAll(
    RegExp(
      r'/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}(?=/|$)',
    ),
    '/:id',
  );
  path = path.replaceAll(RegExp(r'/\d+(?=/|$)'), '/:id');
  return path;
}

Future<void> _writeNetworkDiagnostic(DiagnosticNetworkEvent event) {
  final failed = event.result == 'failure';
  return DiagnosticLogService.instance.record(
    level: failed ? 'error' : 'warning',
    source: '网络',
    type: failed ? '网络请求失败' : '网络请求缓慢',
    summary: failed
        ? '${event.method} ${event.route} 请求失败'
        : '${event.method} ${event.route} 响应较慢',
    detail: [
      'HTTP: ${event.httpStatus ?? "无响应"}',
      '耗时: ${event.durationMs}ms',
      if (event.dioType.isNotEmpty) 'Dio 类型: ${event.dioType}',
      '重试次数: ${event.retryCount}',
      if (event.requestId.isNotEmpty) '请求 ID: ${event.requestId}',
    ].join('\n'),
    eventCode: failed ? 'network_request_failed' : 'network_request_slow',
    category: 'network',
    operation: event.method.toLowerCase(),
    result: event.result,
    durationMs: event.durationMs,
    httpStatus: event.httpStatus,
    retryCount: event.retryCount,
    route: event.route,
    metadata: <String, Object?>{
      'method': event.method,
      if (event.requestId.isNotEmpty) 'requestId': event.requestId,
      if (event.dioType.isNotEmpty) 'dioType': event.dioType,
    },
  );
}
