import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shenliyuan/features/academic/data/academic_server_access_guard.dart';

void main() {
  test('共享 Dio 在网络前阻断旧教务绑定、课表和会话恢复请求', () async {
    final requestedPaths = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid'))
      ..interceptors.add(const AcademicServerAccessGuard())
      ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        requestedPaths.add(options.path);
        handler.resolve(Response(requestOptions: options, statusCode: 200));
      }));
    addTearDown(dio.close);
    for (final path in [
      '/edu/status',
      '/api/edu/courses',
      '/edu/session/resume',
      '/register_with_edu'
    ]) {
      await expectLater(dio.post(path), throwsA(isA<DioException>()));
    }
    expect(requestedPaths, isEmpty);
    await dio.post('/student-identity/verify');
    expect(requestedPaths, ['/student-identity/verify']);
  });

  test('普通 App 接口不受教务服务器闸门影响', () async {
    var reachedNetwork = false;
    final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid'))
      ..interceptors.add(const AcademicServerAccessGuard())
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            reachedNetwork = true;
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: const <String, dynamic>{'ok': true},
              ),
            );
          },
        ),
      );

    final response = await dio.get('/api/posts');

    expect(response.statusCode, 200);
    expect(reachedNetwork, isTrue);
  });

  test('路径分类仍识别旧教务认证别名，由服务端决定是否退役', () {
    for (final path in const [
      '/register_with_edu',
      '/api/login_edu',
      '/api/forgot_password/',
      '/password/edu/reset',
    ]) {
      expect(
          AcademicServerAccessGuard.isAcademicServerPath(
              RequestOptions(path: path)),
          isTrue);
    }
  });
}
