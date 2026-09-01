import 'dart:convert';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';
import 'package:test/test.dart';

import '../helpers/queued_http_adapter.dart';

void main() {
  test('成绩 warmup 的 Set-Cookie 会被同一 CookieJar 带到 AJAX', () async {
    final adapter = QueuedHttpAdapter([
      const QueuedHttpResponse(
        statusCode: 200,
        body: '<html><body>成绩查询</body></html>',
        headers: {
          'content-type': ['text/html'],
          'set-cookie': ['GRADE_ROUTE=GRADE_ROUTE_VALUE; Path=/'],
        },
      ),
      QueuedHttpResponse(
        statusCode: 200,
        body: File('test/fixtures/grades/normal.json').readAsStringSync(),
        headers: const {
          'content-type': ['application/json;charset=UTF-8']
        },
      ),
    ]);
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final jar = CookieJar();
    await jar.saveFromResponse(
      Uri.parse('https://test.local/'),
      [Cookie('JSESSIONID', 'ACTIVE_SESSION')],
    );
    final session = JiaowuSession()
      ..beginLogin('STUDENT_A')
      ..markAuthenticated();
    final client = JiaowuClient(
      baseUrl: 'https://test.local',
      dio: dio,
      cookieJar: jar,
      session: session,
    );

    try {
      final result = await client.getGrades(year: '2026', semester: 3);

      expect(result, isA<GradeFetchResult>());
      expect(result.grades, hasLength(1));
      expect(result.pages, 1);
      expect(result.validEmpty, isFalse);
      expect(result.canonicalJson.single, containsPair('kcmc', '高等数学'));
      expect(result.canonicalJson.single, isNot(contains('xh')));
      expect(result.canonicalJson.single, isNot(contains('xm')));
      expect(result.canonicalJson.single, isNot(contains('TEST_STUDENT')));
      expect(result.canonicalJson.single, isNot(contains('key')));
      expect(adapter.requests, hasLength(2));
      expect(adapter.requests[0].method, 'GET');
      expect(adapter.requests[0].path, '/cjcx/cjcx_cxDgXscj.html');
      expect(adapter.requests[0].queryParameters, {
        'gnmkdm': 'N305005',
        'layout': 'default',
      });
      expect(adapter.requests[1].method, 'POST');
      expect(adapter.requests[1].path, '/cjcx/cjcx_cxXsgrcj.html');
      expect(adapter.requests[1].queryParameters, {
        'doType': 'query',
        'gnmkdm': 'N305005',
      });
      expect(adapter.requests[1].data, {
        'xnm': '2026',
        'xqm': '3',
        'queryModel.showCount': '500',
        'queryModel.currentPage': '1',
      });
      expect(
          requestHeader(adapter.requests[1], 'cookie'),
          allOf(contains('JSESSIONID=ACTIVE_SESSION'),
              contains('GRADE_ROUTE=GRADE_ROUTE_VALUE')));
    } finally {
      client.close(force: true);
    }
  });

  test('成绩页恰好 500 条时继续请求下一页并汇总 517 条', () async {
    final setup = _buildGradeClient([
      _warmupResponse(),
      _jsonResponse('page_500.json'),
      _jsonResponse('page_tail.json'),
    ]);

    try {
      final result = await setup.client.getGrades(year: '2026', semester: 3);

      expect(result.grades, hasLength(517));
      expect(result.pages, 2);
      expect(setup.adapter.requests, hasLength(3));
      expect(setup.adapter.requests[1].data['queryModel.currentPage'], '1');
      expect(setup.adapter.requests[2].data['queryModel.currentPage'], '2');
    } finally {
      setup.client.close(force: true);
    }
  });

  test('成绩页少于 500 条时不请求下一页', () async {
    final allItems =
        jsonDecode(_fixture('page_500.json'))['items'] as List<dynamic>;
    final page499 = jsonEncode({'items': allItems.take(499).toList()});
    final setup = _buildGradeClient([
      _warmupResponse(),
      QueuedHttpResponse(
        statusCode: 200,
        body: page499,
        headers: const {
          'content-type': ['application/json']
        },
      ),
    ]);

    try {
      final result = await setup.client.getGrades(year: '2026', semester: 3);

      expect(result.grades, hasLength(499));
      expect(result.pages, 1);
      expect(setup.adapter.requests, hasLength(2));
    } finally {
      setup.client.close(force: true);
    }
  });

  test('成绩分页达到安全上限时明确失败，不会无限请求', () async {
    final setup = _buildGradeClient([
      _warmupResponse(),
      _jsonResponse('page_500.json'),
      _jsonResponse('page_500.json'),
    ]);

    try {
      await expectLater(
        setup.client.getGrades(year: '2026', semester: 3, maxPages: 2),
        throwsA(
          isA<NetworkException>().having(
            (error) => error.code,
            'code',
            'GRADE_PAGE_LIMIT',
          ),
        ),
      );
      expect(setup.adapter.requests, hasLength(3));
    } finally {
      setup.client.close(force: true);
    }
  });

  test('成绩 items=[] 返回 validEmpty 而不是 GradesNotOpen 异常', () async {
    final setup = _buildGradeClient([
      _warmupResponse(),
      _jsonResponse('empty.json'),
    ]);

    try {
      final result = await setup.client.getGrades(year: '2026', semester: 3);

      expect(result.grades, isEmpty);
      expect(result.validEmpty, isTrue);
      expect(result.pages, 1);
    } finally {
      setup.client.close(force: true);
    }
  });

  test('未认证会话不请求成绩 warmup', () async {
    final setup = _buildGradeClient([], authenticated: false);

    try {
      await expectLater(
        setup.client.getGrades(year: '2026', semester: 3),
        throwsA(isA<UnauthenticatedException>()),
      );
      expect(setup.adapter.requests, isEmpty);
    } finally {
      setup.client.close(force: true);
    }
  });

  test('成绩接口复用学年学期边界并拒绝非法分页上限', () async {
    final invalidRequests = [
      (year: '2026', semester: 1, maxPages: GradeApi.defaultMaxPages),
      (year: '20263', semester: 3, maxPages: GradeApi.defaultMaxPages),
      (year: '2026', semester: 3, maxPages: 0),
    ];

    for (final request in invalidRequests) {
      final setup = _buildGradeClient([]);
      try {
        await expectLater(
          setup.client.getGrades(
            year: request.year,
            semester: request.semester,
            maxPages: request.maxPages,
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(setup.adapter.requests, isEmpty);
      } finally {
        setup.client.close(force: true);
      }
    }
  });

  test('成绩 warmup 的 901、302 和 200 登录页立即结束', () async {
    final cases = [
      (
        response: const QueuedHttpResponse(statusCode: 901, body: ''),
        expected: isA<SessionExpiredException>(),
      ),
      (
        response: const QueuedHttpResponse(statusCode: 302, body: ''),
        expected: isA<SessionExpiredException>(),
      ),
      (
        response: QueuedHttpResponse(
          statusCode: 200,
          body: _fixture('login_page.html'),
        ),
        expected: isA<SessionExpiredException>(),
      ),
    ];

    for (final testCase in cases) {
      final setup = _buildGradeClient([testCase.response]);
      try {
        await expectLater(
          setup.client.getGrades(year: '2026', semester: 3),
          throwsA(testCase.expected),
        );
        expect(setup.client.session.state, SessionState.expired);
        expect(setup.adapter.requests, hasLength(1));
      } finally {
        setup.client.close(force: true);
      }
    }
  });

  test('成绩 warmup 的 500 和 timeout 明确分类', () async {
    final cases = [
      (
        response: const QueuedHttpResponse(statusCode: 500, body: ''),
        expected: isA<NetworkException>().having(
          (error) => error.code,
          'code',
          'GRADE_WARMUP_HTTP',
        ),
      ),
      (
        response: QueuedHttpResponse(
          statusCode: 200,
          body: '',
          error: DioException(
            requestOptions: RequestOptions(path: '/grade-warmup-timeout'),
            type: DioExceptionType.receiveTimeout,
          ),
        ),
        expected: isA<RequestTimeoutException>(),
      ),
    ];

    for (final testCase in cases) {
      final setup = _buildGradeClient([testCase.response]);
      try {
        await expectLater(
          setup.client.getGrades(year: '2026', semester: 3),
          throwsA(testCase.expected),
        );
        expect(setup.adapter.requests, hasLength(1));
      } finally {
        setup.client.close(force: true);
      }
    }
  });

  test('成绩 AJAX 的 901、302 和 200 登录页立即标记会话失效', () async {
    final cases = [
      const QueuedHttpResponse(statusCode: 901, body: ''),
      const QueuedHttpResponse(statusCode: 302, body: ''),
      QueuedHttpResponse(
        statusCode: 200,
        body: _fixture('login_page.html'),
        headers: const {
          'content-type': ['application/json']
        },
      ),
    ];

    for (final response in cases) {
      final setup = _buildGradeClient([_warmupResponse(), response]);
      try {
        await expectLater(
          setup.client.getGrades(year: '2026', semester: 3),
          throwsA(isA<SessionExpiredException>()),
        );
        expect(setup.client.session.state, SessionState.expired);
        expect(setup.adapter.requests, hasLength(2));
      } finally {
        setup.client.close(force: true);
      }
    }
  });

  test('成绩 AJAX 的非 JSON 响应归类为维护异常', () async {
    final setup = _buildGradeClient([
      _warmupResponse(),
      QueuedHttpResponse(
        statusCode: 200,
        body: _fixture('maintenance.html'),
        headers: const {
          'content-type': ['text/html; charset=UTF-8']
        },
      ),
    ]);

    try {
      await expectLater(
        setup.client.getGrades(year: '2026', semester: 3),
        throwsA(
          isA<RemoteMaintenanceException>().having(
            (error) => error.code,
            'code',
            'REMOTE_MAINTENANCE',
          ),
        ),
      );
    } finally {
      setup.client.close(force: true);
    }
  });

  test('成绩 AJAX 的 malformed JSON 返回 ParseException', () async {
    final setup = _buildGradeClient([
      _warmupResponse(),
      QueuedHttpResponse(
        statusCode: 200,
        body: _fixture('malformed.json'),
        headers: const {
          'content-type': ['application/json']
        },
      ),
    ]);

    try {
      await expectLater(
        setup.client.getGrades(year: '2026', semester: 3),
        throwsA(
          isA<ParseException>().having(
            (error) => error.code,
            'code',
            'GRADE_JSON_INVALID',
          ),
        ),
      );
    } finally {
      setup.client.close(force: true);
    }
  });

  test('成绩 AJAX 缺少有效 items 时返回 ProtocolChanged', () async {
    for (final fixture in [
      'missing_items.json',
      'items_null.json',
      'items_wrong_type.json',
    ]) {
      final setup = _buildGradeClient([
        _warmupResponse(),
        _jsonResponse(fixture),
      ]);
      try {
        await expectLater(
          setup.client.getGrades(year: '2026', semester: 3),
          throwsA(isA<ProtocolChangedException>()),
        );
      } finally {
        setup.client.close(force: true);
      }
    }
  });

  test('成绩 AJAX 非 200 返回 NetworkException', () async {
    final setup = _buildGradeClient([
      _warmupResponse(),
      const QueuedHttpResponse(statusCode: 500, body: ''),
    ]);

    try {
      await expectLater(
        setup.client.getGrades(year: '2026', semester: 3),
        throwsA(
          isA<NetworkException>().having(
            (error) => error.code,
            'code',
            'GRADE_HTTP_ERROR',
          ),
        ),
      );
    } finally {
      setup.client.close(force: true);
    }
  });
}

({JiaowuClient client, QueuedHttpAdapter adapter}) _buildGradeClient(
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

QueuedHttpResponse _warmupResponse() => const QueuedHttpResponse(
      statusCode: 200,
      body: '<html><body>成绩查询</body></html>',
      headers: {
        'content-type': ['text/html']
      },
    );

QueuedHttpResponse _jsonResponse(String name) => QueuedHttpResponse(
      statusCode: 200,
      body: _fixture(name),
      headers: const {
        'content-type': ['application/json']
      },
    );

String _fixture(String name) =>
    File('test/fixtures/grades/$name').readAsStringSync();
