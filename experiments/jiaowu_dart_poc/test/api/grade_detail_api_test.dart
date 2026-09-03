import 'package:test/test.dart';
import 'package:dio/dio.dart';
import 'package:jiaowu_dart_poc/src/api/grade_detail_api.dart';
import 'package:jiaowu_dart_poc/src/session/jiaowu_session.dart';
import 'package:jiaowu_dart_poc/src/session/session_state.dart';
import 'package:jiaowu_dart_poc/src/error/jiaowu_exception.dart';

void main() {
  group('GradeDetailApi', () {
    test('uses official detail endpoint with correct parameters', () async {
      const detailHtml = '''
<table>
  <tr><th>成绩分项</th><th>成绩分项比例</th><th>成绩</th></tr>
  <tr><td>【平时】</td><td>15%</td><td>98</td></tr>
  <tr><td>【总评】</td><td></td><td>60.1</td></tr>
</table>
''';

      final posts = <Map<String, dynamic>>[];
      final mockDio = _MockDio(
        baseUrl: 'https://jxw.sylu.edu.cn/xtgl',
        onPost: (url, queryParams, data, options) {
          posts.add({
            'url': url,
            'queryParams': queryParams,
            'data': data,
            'options': options,
          });
          return Response<String>(
            requestOptions: RequestOptions(path: url),
            statusCode: 200,
            data: detailHtml,
            headers: Headers.fromMap({
              'content-type': ['text/html;charset=UTF-8']
            }),
          );
        },
      );

      final session = JiaowuSession();
      session.beginLogin('2021001234');
      session.markAuthenticated();

      final api = GradeDetailApi(dio: mockDio, session: session);

      final detail = await api.fetch(
        year: '2025',
        semester: 12,
        classId: '44DE3FFE6E97156BE0630100050AD0D4',
        courseName: '电磁场与电磁波',
        courseId: '210300504',
        studentGradeId: 'opaque-xh-id',
      );

      expect(detail.success, isTrue);
      expect(detail.totalGrade, '60.1');
      expect(posts, hasLength(1));
      expect(posts[0]['url'], endsWith('/cjcx_cxCjxqGjh.html'));
      expect(posts[0]['queryParams'], {'gnmkdm': 'N305005'});
      expect(posts[0]['data']['jxb_id'], '44DE3FFE6E97156BE0630100050AD0D4');
      expect(posts[0]['data']['xnm'], '2025');
      expect(posts[0]['data']['xqm'], '12');
      expect(posts[0]['data']['xh_id'], 'opaque-xh-id');
      expect(posts[0]['data']['kcmc'], '电磁场与电磁波');
      expect(posts[0]['data']['kch_id'], '210300504');
    });

    test('falls back to second endpoint when first returns no components', () async {
      var callCount = 0;
      final mockDio = _MockDio(
        baseUrl: 'https://jxw.sylu.edu.cn/xtgl',
        onPost: (url, queryParams, data, options) {
          callCount++;
          if (callCount == 1) {
            // First endpoint: no components
            return Response<String>(
              requestOptions: RequestOptions(path: url),
              statusCode: 200,
              data: '{"items": []}',
              headers: Headers.fromMap({
                'content-type': ['application/json']
              }),
            );
          } else {
            // Second endpoint: has components
            return Response<String>(
              requestOptions: RequestOptions(path: url),
              statusCode: 200,
              data: '{"items": [{"cjxmmc": "总评", "xmcj": "85"}]}',
              headers: Headers.fromMap({
                'content-type': ['application/json']
              }),
            );
          }
        },
      );

      final session = JiaowuSession();
      session.beginLogin('2021001234');
      session.markAuthenticated();

      final api = GradeDetailApi(dio: mockDio, session: session);

      final detail = await api.fetch(
        year: '2025',
        semester: 12,
        classId: 'test-class-id',
        courseName: '高等数学',
      );

      expect(detail.success, isTrue);
      expect(detail.totalGrade, '85');
      expect(callCount, 2);
    });

    test('throws SessionExpiredException on 302 status', () async {
      final mockDio = _MockDio(
        baseUrl: 'https://jxw.sylu.edu.cn/xtgl',
        onPost: (url, queryParams, data, options) {
          return Response<String>(
            requestOptions: RequestOptions(path: url),
            statusCode: 302,
            data: '',
            headers: Headers.fromMap({
              'location': ['/login_slogin.html']
            }),
          );
        },
      );

      final session = JiaowuSession();
      session.beginLogin('2021001234');
      session.markAuthenticated();

      final api = GradeDetailApi(dio: mockDio, session: session);

      await expectLater(
        api.fetch(
          year: '2025',
          semester: 12,
          classId: 'test-class-id',
          courseName: '课程',
        ),
        throwsA(isA<SessionExpiredException>()),
      );

      expect(session.state, SessionState.expired);
    });

    test('throws SessionExpiredException on 901 status', () async {
      final mockDio = _MockDio(
        baseUrl: 'https://jxw.sylu.edu.cn/xtgl',
        onPost: (url, queryParams, data, options) {
          return Response<String>(
            requestOptions: RequestOptions(path: url),
            statusCode: 901,
            data: '',
          );
        },
      );

      final session = JiaowuSession();
      session.beginLogin('2021001234');
      session.markAuthenticated();

      final api = GradeDetailApi(dio: mockDio, session: session);

      await expectLater(
        api.fetch(
          year: '2025',
          semester: 12,
          classId: 'test-class-id',
          courseName: '课程',
        ),
        throwsA(isA<SessionExpiredException>()),
      );

      expect(session.state, SessionState.expired);
    });

    test('throws SessionExpiredException when receiving login page', () async {
      final mockDio = _MockDio(
        baseUrl: 'https://jxw.sylu.edu.cn/xtgl',
        onPost: (url, queryParams, data, options) {
          return Response<String>(
            requestOptions: RequestOptions(path: url),
            statusCode: 200,
            data: '''
<html>
  <head><title>统一身份认证</title></head>
  <body>
    <form action="/login_slogin.html" method="post">
      <input type="text" name="yhm" />
      <input type="password" name="mm" />
    </form>
  </body>
</html>
''',
            headers: Headers.fromMap({
              'content-type': ['text/html']
            }),
          );
        },
      );

      final session = JiaowuSession();
      session.beginLogin('2021001234');
      session.markAuthenticated();

      final api = GradeDetailApi(dio: mockDio, session: session);

      await expectLater(
        api.fetch(
          year: '2025',
          semester: 12,
          classId: 'test-class-id',
          courseName: '课程',
        ),
        throwsA(isA<SessionExpiredException>()),
      );

      expect(session.state, SessionState.expired);
    });

    test('returns unavailable detail when all candidates have no components', () async {
      final mockDio = _MockDio(
        baseUrl: 'https://jxw.sylu.edu.cn/xtgl',
        onPost: (url, queryParams, data, options) {
          return Response<String>(
            requestOptions: RequestOptions(path: url),
            statusCode: 200,
            data: '{"items": []}',
            headers: Headers.fromMap({
              'content-type': ['application/json']
            }),
          );
        },
      );

      final session = JiaowuSession();
      session.beginLogin('2021001234');
      session.markAuthenticated();

      final api = GradeDetailApi(dio: mockDio, session: session);

      final detail = await api.fetch(
        year: '2025',
        semester: 12,
        classId: 'test-class-id',
        courseName: '课程',
      );

      expect(detail.success, isFalse);
      expect(detail.components, isEmpty);
      expect(detail.message, isNotNull);
    });

    test('throws UnauthenticatedException when session not authenticated', () {
      final mockDio = _MockDio(baseUrl: 'https://jxw.sylu.edu.cn/xtgl');
      final session = JiaowuSession();

      final api = GradeDetailApi(dio: mockDio, session: session);

      expect(
        () => api.fetch(
          year: '2025',
          semester: 12,
          classId: 'test-class-id',
          courseName: '课程',
        ),
        throwsA(isA<UnauthenticatedException>()),
      );
    });

    test('includes optional parameters in request when provided', () async {
      Map<String, dynamic>? capturedData;
      final mockDio = _MockDio(
        baseUrl: 'https://jxw.sylu.edu.cn/xtgl',
        onPost: (url, queryParams, data, options) {
          capturedData = data;
          return Response<String>(
            requestOptions: RequestOptions(path: url),
            statusCode: 200,
            data: '{"items": [{"cjxmmc": "总评", "xmcj": "85"}]}',
            headers: Headers.fromMap({
              'content-type': ['application/json']
            }),
          );
        },
      );

      final session = JiaowuSession();
      session.beginLogin('2021001234');
      session.markAuthenticated();

      final api = GradeDetailApi(dio: mockDio, session: session);

      await api.fetch(
        year: '2025',
        semester: 12,
        classId: 'test-class-id',
        courseName: '课程',
        courseId: 'course-123',
        studentGradeId: 'grade-456',
      );

      expect(capturedData!['kch_id'], 'course-123');
      expect(capturedData!['kch'], 'course-123');
      expect(capturedData!['xh_id'], 'grade-456');
    });

    test('omits optional parameters from request when not provided', () async {
      Map<String, dynamic>? capturedData;
      final mockDio = _MockDio(
        baseUrl: 'https://jxw.sylu.edu.cn/xtgl',
        onPost: (url, queryParams, data, options) {
          capturedData = data;
          return Response<String>(
            requestOptions: RequestOptions(path: url),
            statusCode: 200,
            data: '{"items": [{"cjxmmc": "总评", "xmcj": "85"}]}',
            headers: Headers.fromMap({
              'content-type': ['application/json']
            }),
          );
        },
      );

      final session = JiaowuSession();
      session.beginLogin('2021001234');
      session.markAuthenticated();

      final api = GradeDetailApi(dio: mockDio, session: session);

      await api.fetch(
        year: '2025',
        semester: 12,
        classId: 'test-class-id',
        courseName: '课程',
      );

      expect(capturedData!.containsKey('kch_id'), isFalse);
      expect(capturedData!.containsKey('kch'), isFalse);
      expect(capturedData!.containsKey('xh_id'), isFalse);
    });
  });
}

class _MockDio implements Dio {
  _MockDio({
    required this.baseUrl,
    this.onPost,
  });

  final String baseUrl;
  final Response<String> Function(
    String url,
    Map<String, dynamic>? queryParams,
    Map<String, dynamic>? data,
    Options? options,
  )? onPost;

  @override
  BaseOptions get options => BaseOptions(baseUrl: baseUrl);

  @override
  Future<Response<T>> post<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    void Function(int, int)? onSendProgress,
    void Function(int, int)? onReceiveProgress,
  }) async {
    if (onPost != null) {
      return onPost!(
        path,
        queryParameters,
        data as Map<String, dynamic>?,
        options,
      ) as Response<T>;
    }
    throw UnimplementedError();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
