import 'package:test/test.dart';
import 'package:dio/dio.dart';
import 'package:jiaowu_dart_poc/src/api/academic_situation_api.dart';
import 'package:jiaowu_dart_poc/src/session/jiaowu_session.dart';
import 'package:jiaowu_dart_poc/src/session/session_state.dart';
import 'package:jiaowu_dart_poc/src/error/jiaowu_exception.dart';

void main() {
  group('AcademicSituationApi', () {
    test('uses official academic situation endpoint with correct parameters',
        () async {
      const situationHtml = '''
<html>
  <body>
    <div>当前所有课程平均学分绩点: 3.75</div>
    <div>当前学位课程平均学分绩点: 3.82</div>
    <div>计划总课程 50 门，通过 45 门，未通过 2 门，未修 3 门，在读 0 门</div>
    <div>计划学位课程 30 门，通过 28 门，未通过 1 门，未修 1 门，在读 0 门</div>
    <table>
      <tr><th>课程名称</th><th>学分</th><th>成绩</th><th>状态</th></tr>
      <tr><td>高等数学</td><td>5.0</td><td>90</td><td>通过</td></tr>
    </table>
  </body>
</html>
''';

      final gets = <Map<String, dynamic>>[];
      final mockDio = _MockDio(
        baseUrl: 'https://jxw.sylu.edu.cn',
        onGet: (url, queryParams, options) {
          gets.add({
            'url': url,
            'queryParams': queryParams,
            'options': options,
          });
          return Response<String>(
            requestOptions: RequestOptions(path: url),
            statusCode: 200,
            data: situationHtml,
            headers: Headers.fromMap({
              'content-type': ['text/html;charset=UTF-8']
            }),
          );
        },
      );

      final session = JiaowuSession();
      session.beginLogin('2021001234');
      session.markAuthenticated();

      final api = AcademicSituationApi(dio: mockDio, session: session);

      final situation = await api.fetch();

      expect(situation.success, isTrue);
      expect(situation.allGpa, 3.75);
      expect(situation.degreeGpa, 3.82);
      expect(situation.totalCourses, 50);
      expect(situation.passedCourses, 45);
      expect(gets, hasLength(1));
      expect(gets[0]['url'], '/xsxy/xsxyqk_cxXsxyqkIndex.html');
      expect(gets[0]['queryParams']['gnmkdm'], 'N105515');
    });

    test('throws SessionExpiredException on 302 status', () async {
      final mockDio = _MockDio(
        baseUrl: 'https://jxw.sylu.edu.cn',
        onGet: (url, queryParams, options) {
          return Response<String>(
            requestOptions: RequestOptions(path: url),
            statusCode: 302,
            data: '<html><body>Redirecting...</body></html>',
            headers: Headers.fromMap({
              'location': ['/login_slogin.html']
            }),
          );
        },
      );

      final session = JiaowuSession();
      session.beginLogin('2021001234');
      session.markAuthenticated();

      final api = AcademicSituationApi(dio: mockDio, session: session);

      await expectLater(
        api.fetch(),
        throwsA(isA<SessionExpiredException>()),
      );

      expect(session.state, SessionState.expired);
    });

    test('throws SessionExpiredException when receiving login page', () async {
      final mockDio = _MockDio(
        baseUrl: 'https://jxw.sylu.edu.cn',
        onGet: (url, queryParams, options) {
          return Response<String>(
            requestOptions: RequestOptions(path: url),
            statusCode: 200,
            data: '''
<html>
  <head><title>统一身份认证</title></head>
  <body>
    <form action="/login_slogin.html">
      <input name="yhm" />
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

      final api = AcademicSituationApi(dio: mockDio, session: session);

      await expectLater(
        api.fetch(),
        throwsA(isA<SessionExpiredException>()),
      );

      expect(session.state, SessionState.expired);
    });
  });
}


class _MockDio implements Dio {
  _MockDio({
    required this.baseUrl,
    this.onGet,
    this.onPost,
  });

  final String baseUrl;
  final Response<String> Function(
    String url,
    Map<String, dynamic>? queryParams,
    Options? options,
  )? onGet;
  final Response<String> Function(
    String url,
    Map<String, dynamic>? queryParams,
    dynamic data,
    Options? options,
  )? onPost;

  @override
  BaseOptions get options => BaseOptions(baseUrl: baseUrl);

  @override
  Future<Response<T>> get<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) async {
    if (onGet != null) {
      return onGet!(path, queryParameters, options) as Response<T>;
    }
    throw UnimplementedError('onGet not provided');
  }

  @override
  Future<Response<T>> post<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async {
    if (onPost != null) {
      return onPost!(path, queryParameters, data, options) as Response<T>;
    }
    throw UnimplementedError('onPost not provided');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

