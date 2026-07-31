import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/diagnostic_dio_interceptor.dart';

void main() {
  test('网络失败只输出规范化路径和错误上下文', () async {
    DiagnosticNetworkEvent? captured;
    final interceptor = DiagnosticDioInterceptor(
      writer: (event) async => captured = event,
    );
    final options = RequestOptions(
      path: '/messages/123/conversations/550e8400-e29b-41d4-a716-446655440000',
      method: 'GET',
      headers: <String, Object?>{'Authorization': 'Bearer secret'},
      data: const <String, Object?>{'message': 'private'},
    );
    options.extra[DiagnosticDioInterceptor.startedAtKey] = 1000;
    final error = DioException(
      requestOptions: options,
      response: Response<void>(requestOptions: options, statusCode: 503),
      type: DioExceptionType.badResponse,
    );

    runZonedGuarded(
      () => interceptor.onError(error, ErrorInterceptorHandler()),
      (_, __) {},
    );
    await Future<void>.delayed(Duration.zero);

    expect(captured?.route, '/messages/:id/conversations/:id');
    expect(captured?.method, 'GET');
    expect(captured?.httpStatus, 503);
    expect(captured?.dioType, 'badResponse');
    expect(captured.toString(), isNot(contains('secret')));
    expect(captured.toString(), isNot(contains('private')));
  });
}
