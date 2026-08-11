import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/app_feedback.dart';
import 'package:shenliyuan/utils/app_navigator.dart';

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

  testWidgets('feedback reserves the bottom safe-area inset', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: scaffoldMessengerKey,
        home: MediaQuery(
          data: const MediaQueryData(
            viewPadding: EdgeInsets.only(bottom: 34),
          ),
          child: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => AppFeedback.info('已复制', context: context),
                child: const Text('显示提示'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('显示提示'));
    await tester.pump();

    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(
      snackBar.margin,
      const EdgeInsets.fromLTRB(16, 0, 16, 50),
    );
  });
}
