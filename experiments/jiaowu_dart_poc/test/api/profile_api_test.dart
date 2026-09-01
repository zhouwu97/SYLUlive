import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';
import 'package:test/test.dart';

import '../helpers/queued_http_adapter.dart';

void main() {
  test('学生信息请求使用固定参数并解析成功', () async {
    final adapter = QueuedHttpAdapter([
      const QueuedHttpResponse(
        statusCode: 200,
        body: '<div id="col_xm"><p>李四</p></div>',
      ),
    ]);
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final session = JiaowuSession()..beginLogin('2026000000');
    session.markAuthenticated();
    final client = JiaowuClient(
      baseUrl: 'https://test.local',
      dio: dio,
      cookieJar: CookieJar(),
      session: session,
    );

    final profile = await client.getProfile();

    expect(profile.name, '李四');
    expect(adapter.requests.single.queryParameters, {
      'gnmkdm': 'N100801',
      'layout': 'default',
      'su': '2026000000',
    });
    client.close(force: true);
  });

  test('200 登录页识别为会话失效而不是解析空数据', () async {
    final adapter = QueuedHttpAdapter([
      const QueuedHttpResponse(
        statusCode: 200,
        body: '<form action="login_slogin.html">用户登录</form>',
      ),
    ]);
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final session = JiaowuSession();
    final client = JiaowuClient(
      baseUrl: 'https://test.local',
      dio: dio,
      cookieJar: CookieJar(),
      session: session,
    );

    await expectLater(
      client.getProfile(),
      throwsA(isA<UnauthenticatedException>()),
    );
    expect(session.state, SessionState.unauthenticated);
    client.close(force: true);
  });

  test('已认证会话只把当前 Session studentId 发给教务接口', () async {
    final adapter = QueuedHttpAdapter([
      const QueuedHttpResponse(
        statusCode: 200,
        body: '<div id="col_xm"><p>李四</p></div>',
      ),
    ]);
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final session = JiaowuSession()..beginLogin('STUDENT_A');
    session.markAuthenticated();
    final client = JiaowuClient(
      baseUrl: 'https://test.local',
      dio: dio,
      cookieJar: CookieJar(),
      session: session,
    );

    await client.getProfile();

    expect(adapter.requests.single.queryParameters['su'], 'STUDENT_A');
    client.close(force: true);
  });
}
