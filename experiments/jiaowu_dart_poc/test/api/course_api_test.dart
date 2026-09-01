import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';
import 'package:test/test.dart';

import '../helpers/queued_http_adapter.dart';

void main() {
  test('Desktop 课表请求按协议参数返回 RawCourse', () async {
    final setup = _buildClient([_jsonResponse('desktop_normal.json')]);
    final client = setup.client;

    try {
      final result = await client.getCourses(year: '2026', semester: 3);

      expect(result, isA<CourseFetchResult>());
      expect(result.source, CourseSource.desktop);
      expect(result.courses, hasLength(3));
      expect(setup.adapter.requests.single.method, 'POST');
      expect(setup.adapter.requests.single.path, '/kbcx/xskbcx_cxXsKb.html');
      expect(
          setup.adapter.requests.single.queryParameters, {'gnmkdm': 'N2154'});
      expect(setup.adapter.requests.single.data, {
        'xnm': '2026',
        'xqm': '3',
        'kblx': '1',
      });
      expect(requestHeader(setup.adapter.requests.single, 'X-Requested-With'),
          'XMLHttpRequest');
      expect(requestHeader(setup.adapter.requests.single, 'Origin'),
          'https://test.local');
      expect(
        requestHeader(setup.adapter.requests.single, 'Referer'),
        'https://test.local/kbcx/xskbcx_cxXsKb.html?gnmkdm=N2154',
      );
    } finally {
      client.close(force: true);
    }
  });

  test('Desktop 合法空课表后回退 Mobile 成功', () async {
    final setup = _buildClient([
      _jsonResponse('desktop_empty.json'),
      _jsonResponse('mobile_normal.json'),
    ]);

    try {
      final result = await setup.client.getCourses(year: '2026', semester: 3);

      expect(result.source, CourseSource.mobile);
      expect(result.courses, hasLength(1));
      expect(setup.adapter.requests[1].path, '/kbcx/xskbcxMobile_cxXsKb.html');
      expect(setup.adapter.requests[1].data, {
        'xnm': '2026',
        'zs': '1',
        'doType': 'app',
        'xqm': '3',
        'kblx': '1',
      });
    } finally {
      setup.client.close(force: true);
    }
  });

  test('Desktop malformed 后回退 Mobile 成功', () async {
    final setup = _buildClient([
      _jsonResponse('malformed.json'),
      _jsonResponse('mobile_normal.json'),
    ]);

    try {
      final result = await setup.client.getCourses(year: '2026', semester: 3);

      expect(result.source, CourseSource.mobile);
      expect(result.courses, hasLength(1));
    } finally {
      setup.client.close(force: true);
    }
  });

  test('Desktop 缺少 kbList 后回退 Mobile 成功', () async {
    final setup = _buildClient([
      _jsonResponse('missing_kblist.json'),
      _jsonResponse('mobile_normal.json'),
    ]);

    try {
      final result = await setup.client.getCourses(year: '2026', semester: 3);

      expect(result.source, CourseSource.mobile);
      expect(result.courses, hasLength(1));
    } finally {
      setup.client.close(force: true);
    }
  });

  test('Desktop timeout 后回退 Mobile 成功', () async {
    final setup = _buildClient([
      QueuedHttpResponse(
        statusCode: 200,
        body: '',
        error: DioException(
          requestOptions: RequestOptions(path: '/course-timeout'),
          type: DioExceptionType.connectionTimeout,
        ),
      ),
      _jsonResponse('mobile_normal.json'),
    ]);

    try {
      final result = await setup.client.getCourses(year: '2026', semester: 3);

      expect(result.source, CourseSource.mobile);
      expect(result.courses, hasLength(1));
    } finally {
      setup.client.close(force: true);
    }
  });

  test('Desktop 901 立即标记 SessionExpired，不回退 Mobile', () async {
    final setup = _buildClient([
      const QueuedHttpResponse(statusCode: 901, body: ''),
      _jsonResponse('mobile_normal.json'),
    ]);

    try {
      await expectLater(
        setup.client.getCourses(year: '2026', semester: 3),
        throwsA(isA<SessionExpiredException>()),
      );
      expect(setup.client.session.state, SessionState.expired);
      expect(setup.adapter.requests, hasLength(1));
    } finally {
      setup.client.close(force: true);
    }
  });

  test('Desktop 302 登录跳转立即标记 SessionExpired', () async {
    final setup = _buildClient([
      QueuedHttpResponse(
        statusCode: 302,
        body: File('test/fixtures/courses/login_page.html').readAsStringSync(),
      ),
      _jsonResponse('mobile_normal.json'),
    ]);

    try {
      await expectLater(
        setup.client.getCourses(year: '2026', semester: 3),
        throwsA(isA<SessionExpiredException>()),
      );
      expect(setup.adapter.requests, hasLength(1));
    } finally {
      setup.client.close(force: true);
    }
  });

  test('Desktop 200 登录页立即标记 SessionExpired', () async {
    final setup = _buildClient([
      QueuedHttpResponse(
        statusCode: 200,
        body: File('test/fixtures/courses/login_page.html').readAsStringSync(),
      ),
      _jsonResponse('mobile_normal.json'),
    ]);

    try {
      await expectLater(
        setup.client.getCourses(year: '2026', semester: 3),
        throwsA(isA<SessionExpiredException>()),
      );
      expect(setup.adapter.requests, hasLength(1));
    } finally {
      setup.client.close(force: true);
    }
  });

  test('两端合法空课表才返回 CourseNotOpen', () async {
    final setup = _buildClient([
      _jsonResponse('desktop_empty.json'),
      _jsonResponse('desktop_empty.json'),
    ]);

    try {
      await expectLater(
        setup.client.getCourses(year: '2026', semester: 3),
        throwsA(isA<CourseNotOpenException>()),
      );
    } finally {
      setup.client.close(force: true);
    }
  });

  test('Desktop 失败且 Mobile 合法空课表返回 CourseNotOpen', () async {
    final setup = _buildClient([
      _jsonResponse('malformed.json'),
      _jsonResponse('desktop_empty.json'),
    ]);

    try {
      await expectLater(
        setup.client.getCourses(year: '2026', semester: 3),
        throwsA(isA<CourseNotOpenException>()),
      );
      expect(setup.adapter.requests, hasLength(2));
      expect(setup.adapter.requests[1].path, '/kbcx/xskbcxMobile_cxXsKb.html');
    } finally {
      setup.client.close(force: true);
    }
  });

  test('两端解析失败返回可区分的 NetworkException', () async {
    final setup = _buildClient([
      _jsonResponse('maintenance.html'),
      _jsonResponse('malformed.json'),
    ]);

    try {
      await expectLater(
        setup.client.getCourses(year: '2026', semester: 3),
        throwsA(
          isA<NetworkException>().having(
            (error) => error.code,
            'code',
            'COURSE_FETCH_UNPARSABLE',
          ),
        ),
      );
    } finally {
      setup.client.close(force: true);
    }
  });

  test('未认证会话禁止发起课表请求', () async {
    final setup = _buildClient([], authenticated: false);

    try {
      await expectLater(
        setup.client.getCourses(year: '2026', semester: 3),
        throwsA(isA<UnauthenticatedException>()),
      );
      expect(setup.adapter.requests, isEmpty);
    } finally {
      setup.client.close(force: true);
    }
  });

  test('canonical JSON 按周次、节次和课程字段稳定排序', () async {
    final setup = _buildClient([_jsonResponse('desktop_normal.json')]);

    try {
      final result = await setup.client.getCourses(year: '2026', semester: 3);

      expect(result.canonicalJson, [
        {
          'name': '高等数学',
          'teacher': '张老师',
          'location': 'A101',
          'section': '1-2节',
          'weekday': '1',
          'weeks': '1-8周',
        },
        {
          'name': '高等数学',
          'teacher': '张老师',
          'location': 'A202',
          'section': '1-2节',
          'weekday': '1',
          'weeks': '9-16周',
        },
        {
          'name': '大学英语',
          'teacher': '李老师',
          'location': 'B201',
          'section': '3-4节',
          'weekday': '2',
          'weeks': '1-16周(单)',
        },
      ]);
    } finally {
      setup.client.close(force: true);
    }
  });
}

({JiaowuClient client, QueuedHttpAdapter adapter}) _buildClient(
  Iterable<QueuedHttpResponse> responses, {
  bool authenticated = true,
}) {
  final adapter = QueuedHttpAdapter(responses);
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = adapter;
  final session = JiaowuSession();
  if (authenticated) {
    session
      ..beginLogin('STUDENT_A')
      ..markAuthenticated();
  }
  final client = JiaowuClient(
    baseUrl: 'https://test.local',
    dio: dio,
    cookieJar: CookieJar(),
    session: session,
  );
  return (client: client, adapter: adapter);
}

QueuedHttpResponse _jsonResponse(String fixtureName) => QueuedHttpResponse(
      statusCode: 200,
      body: File('test/fixtures/courses/$fixtureName').readAsStringSync(),
      headers: const {
        'content-type': ['application/json']
      },
    );
