import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/academic_transfer/academic_transfer_service.dart';

void main() {
  test('App 的 /api 基址只拼接一次，领取与取消使用同一个会话地址', () async {
    final requests = <RequestOptions>[];
    final dio = Dio(BaseOptions(baseUrl: 'https://sylulive.online/api'));
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requests.add(options);
      handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: {}));
    }));
    final api = AcademicTransferApi(dio, appUserId: '7');
    await api.claim('synthetic-session');
    await api.cancel('synthetic-session');
    expect(requests.map((r) => r.uri.path), [
      '/api/academic-transfer/sessions/synthetic-session/claim',
      '/api/academic-transfer/sessions/synthetic-session',
    ]);
    expect(
        requests.every((r) => r.headers['X-Expected-App-User'] == '7'), isTrue);
  });
}
