import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/app_feedback.dart';

void main() {
  test('handles Dio transform timeout as a service timeout', () {
    final error = DioException(
      requestOptions: RequestOptions(path: '/test'),
      type: DioExceptionType.transformTimeout,
    );

    final message = AppFeedback.dioErrorMessage(
      error,
      serviceName: 'Edu API',
      fallback: 'fallback',
    );

    expect(message, contains('Edu API'));
    expect(message, isNot('fallback'));
  });
}
