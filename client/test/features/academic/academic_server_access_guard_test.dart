import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shenliyuan/features/academic/data/academic_server_access_guard.dart';

void main() {
  test('阻断共享 Dio 上的相对教务服务器路径', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid'))
      ..interceptors.add(const AcademicServerAccessGuard());

    await expectLater(
      dio.get('/edu/status'),
      throwsA(
        isA<DioException>().having(
          (error) => error.message,
          'message',
          '教务服务器接口已阻断，请使用本机直连教务',
        ),
      ),
    );
    await expectLater(
      dio.post('/api/edu/courses'),
      throwsA(isA<DioException>()),
    );
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
}
