import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/diagnostic_dio_interceptor.dart';
import 'package:shenliyuan/services/retry_interceptor.dart';

void main() {
  group('SafeRetryInterceptor Tests', () {
    test('parseRetryAfterMs correctly parses integer seconds and dates', () {
      expect(parseRetryAfterMs(null), isNull);
      expect(parseRetryAfterMs(''), isNull);
      expect(parseRetryAfterMs('  '), isNull);
      expect(parseRetryAfterMs('5'), 5000);
      expect(parseRetryAfterMs(' 12 '), 12000);
      expect(parseRetryAfterMs('0'), 0);

      // Future ISO date
      final futureDate = DateTime.now().add(const Duration(seconds: 10));
      final parsedMs = parseRetryAfterMs(futureDate.toIso8601String());
      expect(parsedMs, isNotNull);
      expect(parsedMs!, greaterThan(8000));
      expect(parsedMs, lessThanOrEqualTo(11000));
    });

    test('cancellableDelay resolves true if not cancelled and false if cancelled',
        () async {
      final token = CancelToken();
      final future = cancellableDelay(const Duration(milliseconds: 300), token);
      token.cancel('user cancelled');
      final result = await future;
      expect(result, isFalse);

      final fastResult =
          await cancellableDelay(const Duration(milliseconds: 1), null);
      expect(fastResult, isTrue);
    });

    test('Retry respects request budget and skips retry when budget is exceeded',
        () async {
      final dio = Dio();
      final interceptor = SafeRetryInterceptor(
        dio,
        delayFn: (duration, cancelToken) async {},
      );

      final options = RequestOptions(
        path: '/api/posts',
        method: 'GET',
        extra: <String, dynamic>{
          'request_budget_ms': 500,
          DiagnosticDioInterceptor.logicalStartedAtKey:
              DateTime.now().millisecondsSinceEpoch - 600,
        },
      );

      final error = DioException(
        requestOptions: options,
        response: Response<void>(requestOptions: options, statusCode: 503),
        type: DioExceptionType.badResponse,
      );

      bool nextCalled = false;

      await interceptor.onError(
        error,
        _MockErrorHandler(onNext: (err) {
          nextCalled = true;
        }),
      );

      expect(nextCalled, isTrue);
      // Attempt should NOT be incremented because retry was skipped due to budget
      expect(options.extra['_safe_retry_attempt'], isNull);
    });

    test('DiagnosticDioInterceptor suppresses intermediate error when willRetryKey is set',
        () async {
      DiagnosticNetworkEvent? captured;
      final interceptor = DiagnosticDioInterceptor(
        writer: (event) async => captured = event,
      );

      final options = RequestOptions(
        path: '/api/posts',
        method: 'GET',
        extra: <String, dynamic>{
          DiagnosticDioInterceptor.willRetryKey: true,
        },
      );

      final error = DioException(
        requestOptions: options,
        response: Response<void>(requestOptions: options, statusCode: 503),
        type: DioExceptionType.badResponse,
      );

      interceptor.onError(error, _MockErrorHandler(onNext: (_) {}));
      await Future<void>.delayed(Duration.zero);

      expect(captured, isNull);
    });
  });
}

class _MockErrorHandler extends ErrorInterceptorHandler {
  _MockErrorHandler({required this.onNext});
  final void Function(DioException err) onNext;

  @override
  void next(DioException err) {
    onNext(err);
  }
}
