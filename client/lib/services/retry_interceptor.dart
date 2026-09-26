import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/api_constants.dart';
import 'diagnostic_dio_interceptor.dart';

int? parseRetryAfterMs(String? rawHeader) {
  if (rawHeader == null) return null;
  final trimmed = rawHeader.trim();
  if (trimmed.isEmpty) return null;
  final seconds = int.tryParse(trimmed);
  if (seconds != null) {
    return seconds > 0 ? seconds * 1000 : 0;
  }
  try {
    final httpDate = HttpDate.parse(trimmed);
    final diffMs = httpDate.difference(DateTime.now()).inMilliseconds;
    return diffMs > 0 ? diffMs : 0;
  } catch (_) {}
  final parsedIso = DateTime.tryParse(trimmed);
  if (parsedIso != null) {
    final diffMs = parsedIso.difference(DateTime.now()).inMilliseconds;
    return diffMs > 0 ? diffMs : 0;
  }
  return null;
}

Future<bool> cancellableDelay(
  Duration delay,
  CancelToken? cancelToken,
) async {
  if (cancelToken?.isCancelled == true) return false;
  if (delay <= Duration.zero) return true;

  final completer = Completer<bool>();
  Timer? timer;

  void onCancel() {
    timer?.cancel();
    if (!completer.isCompleted) {
      completer.complete(false);
    }
  }

  timer = Timer(delay, () {
    if (!completer.isCompleted) {
      completer.complete(true);
    }
  });

  if (cancelToken != null) {
    unawaited(cancelToken.whenCancel.then((_) => onCancel()));
  }

  return completer.future;
}

/// 只为幂等请求提供有限次、带退避的重试。
///
/// POST/PUT/PATCH/DELETE 默认不重试，避免网络结果不确定时重复创建或提交
/// 业务数据。需要重试的写请求必须由业务层显式实现幂等键与自己的重试策略。
class SafeRetryInterceptor extends Interceptor {
  SafeRetryInterceptor(
    this._dio, {
    this.delayFn,
  });

  final Dio _dio;
  final Random _random = Random();
  final Future<void> Function(Duration duration, CancelToken? cancelToken)? delayFn;

  static const _attemptKey = '_safe_retry_attempt';
  static const _disableKey = 'disable_safe_retry';
  static const requestBudgetMsKey = 'request_budget_ms';

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
    final baseDelayMs = nextAttempt == 1 ? 300 : 900;
    final jitterMs = _random.nextInt(120);
    var calculatedDelayMs = baseDelayMs + jitterMs;

    final retryAfterHeader = error.response?.headers.value('retry-after');
    final parsedRetryAfter = parseRetryAfterMs(retryAfterHeader);
    if (parsedRetryAfter != null) {
      calculatedDelayMs = parsedRetryAfter.clamp(0, 15000);
    }

    final budgetMs = (options.extra[requestBudgetMsKey] as num?)?.toInt();
    final logicalStart =
        (options.extra[DiagnosticDioInterceptor.logicalStartedAtKey] as num?)
                ?.toInt() ??
            DateTime.now().millisecondsSinceEpoch;
    final elapsedMs = DateTime.now().millisecondsSinceEpoch - logicalStart;

    if (budgetMs != null && (elapsedMs + calculatedDelayMs >= budgetMs)) {
      if (kDebugMode) {
        debugPrint(
          '[HTTP] retry skipped due to budget exceeded: elapsed=${elapsedMs}ms + delay=${calculatedDelayMs}ms >= budget=${budgetMs}ms',
        );
      }
      handler.next(error);
      return;
    }

    options.extra[_attemptKey] = nextAttempt;
    options.extra[DiagnosticDioInterceptor.retryCountKey] = nextAttempt;
    options.extra[DiagnosticDioInterceptor.willRetryKey] = true;

    if (kDebugMode) {
      debugPrint(
        '[HTTP] retry $nextAttempt/${ApiConstants.maxRetries} '
        '${options.method} ${options.uri.path} in ${calculatedDelayMs}ms',
      );
    }

    bool shouldProceed = true;
    if (delayFn != null) {
      await delayFn!(
        Duration(milliseconds: calculatedDelayMs),
        options.cancelToken,
      );
      if (options.cancelToken?.isCancelled == true) {
        shouldProceed = false;
      }
    } else {
      shouldProceed = await cancellableDelay(
        Duration(milliseconds: calculatedDelayMs),
        options.cancelToken,
      );
    }

    if (!shouldProceed || options.cancelToken?.isCancelled == true) {
      options.extra.remove(DiagnosticDioInterceptor.willRetryKey);
      handler.next(error);
      return;
    }

    try {
      final response = await _dio.fetch<dynamic>(options);
      options.extra.remove(DiagnosticDioInterceptor.willRetryKey);
      handler.resolve(response);
    } on DioException catch (retryError) {
      options.extra.remove(DiagnosticDioInterceptor.willRetryKey);
      handler.next(retryError);
    } catch (_) {
      options.extra.remove(DiagnosticDioInterceptor.willRetryKey);
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
