import 'package:test/test.dart';
import 'package:dio/dio.dart';
import 'package:jiaowu_dart_poc/src/api/credit_requirement_api.dart';
import 'package:jiaowu_dart_poc/src/session/jiaowu_session.dart';
import 'package:jiaowu_dart_poc/src/session/session_state.dart';
import 'package:jiaowu_dart_poc/src/error/jiaowu_exception.dart';

void main() {
  group('CreditRequirementApi', () {
    test('fetches entry page and then AJAX data', () async {
      const entryHtml = '''
<html>
  <body>
    <input type="hidden" id="ccdm" name="ccdm" value="2021" />
    <input type="hidden" id="xsbj" name="xsbj" value="202101" />
  </body>
</html>
''';

      const ajaxHtml = '''
<html>
  <body>
    <h3>通识教育课程 (要求最低学分: 30)</h3>
    <table>
      <tr>
        <th>课程号</th>
        <th>课程名称</th>
        <th>学分</th>
        <th>成绩</th>
      </tr>
      <tr>
        <td>001</td>
        <td>大学英语</td>
        <td>4.0</td>
        <td>90</td>
      </tr>
    </table>
  </body>
</html>
''';

      var callCount = 0;
      final mockDio = _MockDio(
        baseUrl: 'https://jxw.sylu.edu.cn',
        onGet: (url, queryParams, options) {
          callCount++;
          // First call: entry page
          return Response<String>(
            requestOptions: RequestOptions(path: url),
            statusCode: 200,
            data: entryHtml,
            headers: Headers.fromMap({
              'content-type': ['text/html;charset=UTF-8']
            }),
          );
        },
        onPost: (url, queryParams, data, options) {
          // Second call: AJAX data
          return Response<String>(
            requestOptions: RequestOptions(path: url),
            statusCode: 200,
            data: ajaxHtml,
            headers: Headers.fromMap({
              'content-type': ['text/html;charset=UTF-8']
            }),
          );
        },
      );

      final session = JiaowuSession();
      session.beginLogin('2021001234');
      session.markAuthenticated();

      final api = CreditRequirementApi(dio: mockDio, session: session);

      final requirement = await api.fetch();

      expect(requirement.success, isTrue);
      expect(requirement.status, 'available');
      expect(requirement.modules, hasLength(1));
      expect(requirement.modules[0].name, '通识教育课程');
      expect(requirement.modules[0].requiredCredits, 30.0);
      expect(callCount, 1); // GET was called once
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

      final api = CreditRequirementApi(dio: mockDio, session: session);

      await expectLater(
        api.fetch(),
        throwsA(isA<SessionExpiredException>()),
      );

      expect(session.state, SessionState.expired);
    });

    test('handles empty AJAX response', () async {
      const entryHtml = '''
<html>
  <body>
    <input type="hidden" id="ccdm" name="ccdm" value="2021" />
    <input type="hidden" id="xsbj" name="xsbj" value="202101" />
  </body>
</html>
''';

      const ajaxHtml = '''
<html>
  <body>
    <p>暂无学分要求数据</p>
  </body>
</html>
''';

      final mockDio = _MockDio(
        baseUrl: 'https://jxw.sylu.edu.cn',
        onGet: (url, queryParams, options) {
          return Response<String>(
            requestOptions: RequestOptions(path: url),
            statusCode: 200,
            data: entryHtml,
            headers: Headers.fromMap({
              'content-type': ['text/html;charset=UTF-8']
            }),
          );
        },
        onPost: (url, queryParams, data, options) {
          return Response<String>(
            requestOptions: RequestOptions(path: url),
            statusCode: 200,
            data: ajaxHtml,
            headers: Headers.fromMap({
              'content-type': ['text/html;charset=UTF-8']
            }),
          );
        },
      );

      final session = JiaowuSession();
      session.beginLogin('2021001234');
      session.markAuthenticated();

      final api = CreditRequirementApi(dio: mockDio, session: session);

      final requirement = await api.fetch();

      expect(requirement.success, isFalse);
      expect(requirement.status, 'empty');
      expect(requirement.modules, isEmpty);
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

