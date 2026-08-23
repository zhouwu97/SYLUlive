import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/api_constants.dart';

/// 只为幂等请求提供有限次、带退避的重试。
///
/// POST/PUT/PATCH/DELETE 默认不重试，避免网络结果不确定时重复创建或提交
/// 业务数据。需要重试的写请求必须由业务层显式实现幂等键与自己的重试策略。
class SafeRetryInterceptor extends Interceptor {
  SafeRetryInterceptor(this._dio);

  final Dio _dio;
  final Random _random = Random();

  static const _attemptKey = '_safe_retry_attempt';
  static const _disableKey = 'disable_safe_retry';

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final error = err;
    final options = error.requestOptions;
    final method = options.method.toUpperCase();
    final attempt = (options.extra[_attemptKey] as num?)?.toInt() ?? 0;

    if (!_shouldRetry(error, method, options) ||
        attempt >= ApiConstants.maxRetries) {
      handler.next(error);
      return;
    }

    final nextAttempt = attempt + 1;
    options.extra[_attemptKey] = nextAttempt;
    final baseDelayMs = nextAttempt == 1 ? 300 : 900;
    final jitterMs = _random.nextInt(120);

    if (kDebugMode) {
      debugPrint(
        '[HTTP] retry $nextAttempt/${ApiConstants.maxRetries} '
        '${options.method} ${options.uri.path} in ${baseDelayMs + jitterMs}ms',
      );
    }

    await Future<void>.delayed(
      Duration(milliseconds: baseDelayMs + jitterMs),
    );

    if (options.cancelToken?.isCancelled == true) {
      handler.next(error);
      return;
    }

    try {
      final response = await _dio.fetch<dynamic>(options);
      handler.resolve(response);
    } on DioException catch (retryError) {
      handler.next(retryError);
    } catch (_) {
      handler.next(error);
    }
  }

  bool _shouldRetry(
    DioException error,
    String method,
    RequestOptions options,
  ) {
    if (options.extra[_disableKey] == true) return false;
    if (method != 'GET' && method != 'HEAD') return false;
    if (error.type == DioExceptionType.cancel) return false;

    final status = error.response?.statusCode;
    if (status != null) {
      return status == 408 || status == 425 || status == 429 || status >= 500;
    }

    return error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.unknown;
  }
}
