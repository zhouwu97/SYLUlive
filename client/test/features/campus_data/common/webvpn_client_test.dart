import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/campus_data/common/campus_data_exception.dart';
import 'package:shenliyuan/features/campus_data/common/webvpn_client.dart';

void main() {
  group('WebVpnClient', () {
    test('uses CAS entry, pwdFromId form, full fields, and verifies ticket',
        () async {
      final adapter = _FakeAdapter();
      final jar = CookieJar();
      final dio = Dio()..httpClientAdapter = adapter;
      dio.interceptors.add(CookieManager(jar));

      adapter.register(
        'GET',
        'https://webvpn.sylu.edu.cn/login?cas_login=true',
        (options, body) => ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['/authserver/login?service=webvpn'],
          },
        ),
      );
      adapter.register(
        'GET',
        'https://webvpn.sylu.edu.cn/authserver/login?service=webvpn',
        (options, body) => ResponseBody.fromString(
          '''
          <html>
            <head><title>CAS Login</title></head>
            <body>
              <form id="pwdFromId" action="/authserver/login" method="post">
                <input id="pwdEncryptSalt" value="1234567890abcdef" />
                <input name="execution" value="exec-token" />
              </form>
            </body>
          </html>
          ''',
          200,
          headers: {
            'content-type': ['text/html; charset=utf-8'],
          },
        ),
      );
      adapter.registerPrefix(
        'POST',
        'https://webvpn.sylu.edu.cn/authserver/login?service=',
        (options, body) => ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['/'],
            'set-cookie': [
              'wengine_vpn_ticketwebvpn_sylu_edu_cn=ticket-value; Path=/; HttpOnly',
            ],
          },
        ),
      );

      await WebVpnClient(dio: dio, cookieJar: jar)
          .login('2024000001', 'secret');

      expect(adapter.requests.first.uri.toString(),
          'https://webvpn.sylu.edu.cn/login?cas_login=true');

      final postBody = Uri.splitQueryString(adapter.requestBodies.last);
      expect(postBody['username'], '2024000001');
      expect(postBody['password'], isNotEmpty);
      expect(postBody['_eventId'], 'submit');
      expect(postBody['cllt'], 'userNameLogin');
      expect(postBody['dllt'], 'generalLogin');
      expect(postBody['lt'], '');
      expect(postBody['execution'], 'exec-token');

      final postUri = adapter.requests.last.uri;
      expect(postUri.path, '/authserver/login');
      expect(postUri.queryParameters['service'],
          'https://webvpn.sylu.edu.cn/login?cas_login=true');

      final cookies =
          await jar.loadForRequest(Uri.parse('https://webvpn.sylu.edu.cn/'));
      expect(
        cookies.any((cookie) =>
            cookie.name == 'wengine_vpn_ticketwebvpn_sylu_edu_cn' &&
            cookie.value == 'ticket-value'),
        isTrue,
      );
    });

    test('classifies missing CAS password form as WebVPN page change',
        () async {
      final adapter = _FakeAdapter();
      final dio = Dio()..httpClientAdapter = adapter;

      adapter.register(
        'GET',
        'https://webvpn.sylu.edu.cn/login?cas_login=true',
        (options, body) => ResponseBody.fromString(
          '<html><title>Portal</title><body>No login form</body></html>',
          200,
          headers: {
            'content-type': ['text/html; charset=utf-8'],
          },
        ),
      );

      expect(
        () => WebVpnClient(dio: dio).login('user', 'secret'),
        throwsA(isA<WebVpnPageChangedException>()),
      );
    });
  });
}

typedef _Responder = ResponseBody Function(RequestOptions options, String body);

class _FakeAdapter implements HttpClientAdapter {
  final _routes = <_Route>[];
  final requests = <RequestOptions>[];
  final requestBodies = <String>[];

  void register(String method, String url, _Responder responder) {
    _routes.add(_Route(method, url, false, responder));
  }

  void registerPrefix(String method, String urlPrefix, _Responder responder) {
    _routes.add(_Route(method, urlPrefix, true, responder));
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = requestStream == null
        ? ''
        : utf8.decode(
            await requestStream
                .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk)),
          );

    requests.add(options);
    requestBodies.add(body);

    final url = options.uri.toString();
    for (final route in _routes) {
      if (route.matches(options.method, url)) {
        return route.responder(options, body);
      }
    }

    return ResponseBody.fromString('No route for ${options.method} $url', 404);
  }

  @override
  void close({bool force = false}) {}
}

class _Route {
  final String method;
  final String url;
  final bool prefix;
  final _Responder responder;

  _Route(this.method, this.url, this.prefix, this.responder);

  bool matches(String requestMethod, String requestUrl) {
    if (method != requestMethod.toUpperCase()) {
      return false;
    }
    return prefix ? requestUrl.startsWith(url) : requestUrl == url;
  }
}
