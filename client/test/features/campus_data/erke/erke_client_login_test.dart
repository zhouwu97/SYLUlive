import 'dart:convert';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_client.dart';

class _Client extends ErkeClient {
  _Client({required super.dio});

  @override
  String encryptRsa(String plainText, String publicKeyBase64) => 'ciphertext';
}

const _login = '<input id="pubKey" value="fixture-key">'
    '<input id="UserName"><input id="Password"><span id="code-box">K777</span>';

String _graduation() => '${[
      'A',
      'B',
      'C',
      'D',
      'E'
    ].map((c) => '<span id="Count$c">10</span><span id="Count${c}1">5</span>').join()}'
    '<span id="SunCount">50</span><span id="SunCount1">25</span>';

void main() {
  test('逐跳保存 Cookie，并用前一跳会话继续请求', () async {
    final dio = Dio(BaseOptions(
        followRedirects: false, validateStatus: (s) => s != null && s < 500));
    dio.interceptors.add(CookieManager(CookieJar()));
    final requests = <String>[];
    dio.httpClientAdapter = _Adapter((options) {
      requests.add(options.uri.path);
      if (options.method == 'POST') {
        return ResponseBody.fromString('', 302, headers: {
          'location': ['ticket'],
          'set-cookie': ['erke_session=fixture; Path=/; Secure'],
        });
      }
      if (options.path.endsWith('/ticket')) {
        expect(options.headers['cookie'], contains('erke_session=fixture'));
        return ResponseBody.fromString('', 302, headers: {
          'location': ['SystemForm/main.htm'],
          'set-cookie': ['step=fixture; Path=/; Secure'],
        });
      }
      if (options.path.endsWith('/main.htm')) {
        expect(options.headers['cookie'], contains('erke_session=fixture'));
        expect(options.headers['cookie'], contains('step=fixture'));
        return ResponseBody.fromString('<frameset></frameset>', 200, headers: {
          'content-type': ['text/html; charset=utf-8']
        });
      }
      return ResponseBody.fromString(_login, 200, headers: {
        'content-type': ['text/html; charset=utf-8']
      });
    });
    await _Client(dio: dio).loginToErke('fixture-student', 'fixture-secret');
    expect(requests.last, endsWith('/Sys/SystemForm/main.htm'));
  });

  for (final recovered in [true, false]) {
    test('上游模糊失败只重试一次，恢复结果：$recovered', () async {
      final dio = Dio();
      var posts = 0;
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        var html = _login;
        if (options.method == 'POST') {
          posts++;
          html = recovered && posts == 2
              ? '<script>window.location.href = "SystemForm/main.htm";</script>'
              : "<script>alert('密码错误');</script>";
        }
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            headers: Headers.fromMap({
              'content-type': ['text/html; charset=utf-8']
            }),
            data: utf8.encode(html)));
      }));
      final login =
          _Client(dio: dio).loginToErke('fixture-student', 'fixture-secret');
      if (recovered) {
        await login;
      } else {
        await expectLater(login, throwsA(isA<ErkeLoginException>()));
      }
      expect(posts, 2);
    });
  }

  test('活动接口退回登录页时不能当成零活动成功', () async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          headers: Headers.fromMap({
            'content-type': ['text/html; charset=utf-8']
          }),
          data: utf8.encode(_login)));
    }));
    await expectLater(
        _Client(dio: dio).getActivities(), throwsA(isA<ErkeLoginException>()));
  });
  test('HTTP 跳转登录成功，并且不提交明文 Password', () async {
    final dio = Dio();
    final requests = <RequestOptions>[];
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requests.add(options);
      final post = options.method == 'POST';
      final main = options.path.endsWith('/SystemForm/main.htm');
      if (post) {
        final body = options.data as String;
        expect(body.split('&'), contains('Password='));
        expect(body.split('&'), contains('pwd=ciphertext'));
        expect(body, isNot(contains('fixture-secret')));
        expect(body, contains('queryBtn=%B5%C7++++++++++++%C2%BC'));
      }
      handler.resolve(Response(
        requestOptions: options,
        statusCode: post ? 302 : 200,
        headers: Headers.fromMap({
          'content-type': ['text/html; charset=utf-8'],
          if (post) 'location': ['SystemForm/main.htm'],
        }),
        data: utf8.encode(post
            ? ''
            : main
                ? '<frameset></frameset>'
                : _login),
      ));
    }));
    final client = _Client(dio: dio);
    await client.loginToErke('fixture-student', 'fixture-secret');
    expect(requests.last.path, endsWith('/Sys/SystemForm/main.htm'));
  });

  test('上游提示密码错误但已建立会话时，以受保护成绩页确认为准', () async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      final html = options.method == 'POST'
          ? "<script>alert('密码错误');</script>"
          : options.path.endsWith('StuFinishStudentScore.aspx')
              ? _graduation()
              : _login;
      handler.resolve(Response(
        requestOptions: options,
        statusCode: 200,
        headers: Headers.fromMap({
          'content-type': ['text/html; charset=utf-8']
        }),
        data: utf8.encode(html),
      ));
    }));
    await _Client(dio: dio).loginToErke('fixture-student', 'fixture-secret');
  });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final ResponseBody Function(RequestOptions) respond;
  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      respond(options);
  @override
  void close({bool force = false}) {}
}
