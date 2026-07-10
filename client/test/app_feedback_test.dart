import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/app_feedback.dart';

void main() {
  test('handles Dio receive timeout as a service timeout', () {
    final error = DioException(
      requestOptions: RequestOptions(path: '/test'),
      type: DioExceptionType.receiveTimeout,
    );

    final message = AppFeedback.dioErrorMessage(
      error,
      serviceName: 'Edu API',
      fallback: 'fallback',
    );

    expect(message, contains('Edu API'));
    expect(message, isNot('fallback'));
  });

  test('handles Dio transform timeout as a service processing timeout', () {
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
    expect(message, contains('响应处理超时'));
    expect(message, isNot('fallback'));
  });
}
