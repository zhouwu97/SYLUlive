import 'dart:convert';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/key_generators/api.dart';
import 'package:pointycastle/key_generators/rsa_key_generator.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:test/test.dart';

import '../helpers/queued_http_adapter.dart';

void main() {
  test('验证码登录复用同一 CookieJar，并在续登时提交 yzm', () async {
    final keyPair = _newKeyPair();
    final publicKeyBody = _publicKeyBody(keyPair.publicKey);
    final adapter = QueuedHttpAdapter([
      QueuedHttpResponse(
        statusCode: 200,
        body: '<input id="csrftoken" name="csrftoken" value="CSRF_A">',
        headers: {
          'set-cookie': ['JSESSIONID=SESSION_A; Path=/'],
        },
      ),
      QueuedHttpResponse(statusCode: 200, body: publicKeyBody),
      QueuedHttpResponse(
        statusCode: 200,
        body: '<script>alert("请输入验证码");</script>',
      ),
      QueuedHttpResponse(
        statusCode: 200,
        body: '',
        headers: {
          'content-type': ['image/png'],
        },
        bodyBytes: Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]),
      ),
      QueuedHttpResponse(statusCode: 200, body: publicKeyBody),
      QueuedHttpResponse(
        statusCode: 302,
        body: '',
        headers: {
          'location': ['/xtgl/index_initMenu.html'],
          'set-cookie': ['AUTH=AUTH_SESSION; Path=/'],
        },
      ),
      QueuedHttpResponse(
        statusCode: 200,
        body: '<div id="col_xm"><p>张三</p></div>',
      ),
    ]);
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final client = JiaowuClient(dio: dio, baseUrl: 'https://test.local');

    final first = await client.login(
      studentId: '2026000000',
      password: '校园密码-测试',
    );
    expect(first, isA<CaptchaRequired>());
    expect(client.session.state, SessionState.awaitingCaptcha);

    final challenge = await client.getCaptchaChallenge();
    expect(challenge.imageBytes, [137, 80, 78, 71, 13, 10, 26, 10]);

    final continued = await client.continueLoginWithCaptcha(code: 'A7k2');
    expect(continued, isA<LoginSuccess>());
    expect(client.session.state, SessionState.authenticated);
    expect(adapter.requests, hasLength(7));
    expect(
      requestHeader(adapter.requests[3], 'cookie'),
      contains('JSESSIONID=SESSION_A'),
    );
    expect(
      requestHeader(adapter.requests[5], 'cookie'),
      contains('JSESSIONID=SESSION_A'),
    );
    final continuationData = adapter.requests[5].data as Map<dynamic, dynamic>;
    expect(continuationData['yzm'], 'A7k2');
    expect(continuationData['yhm'], '2026000000');
    expect(continuationData['csrftoken'], 'CSRF_A');
    expect(continuationData['mm'], isNot('校园密码-测试'));

    client.close(force: true);
  });

  test('验证码错误时保留 pending 登录和 Cookie，不重置 Session', () async {
    final keyPair = _newKeyPair();
    final publicKeyBody = _publicKeyBody(keyPair.publicKey);
    final adapter = QueuedHttpAdapter([
      const QueuedHttpResponse(
        statusCode: 200,
        body: '<input id="csrftoken" value="CSRF_A">',
        headers: {
          'set-cookie': ['JSESSIONID=SESSION_A; Path=/'],
        },
      ),
      QueuedHttpResponse(statusCode: 200, body: publicKeyBody),
      const QueuedHttpResponse(
        statusCode: 200,
        body: '<script>alert("验证码错误");</script>',
      ),
      QueuedHttpResponse(
        statusCode: 200,
        body: '',
        headers: {
          'content-type': ['image/jpeg'],
        },
        bodyBytes: Uint8List.fromList([255, 216, 255, 224]),
      ),
      QueuedHttpResponse(statusCode: 200, body: publicKeyBody),
      const QueuedHttpResponse(
        statusCode: 200,
        body: '<script>alert("验证码错误");</script>',
      ),
    ]);
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final client = JiaowuClient(dio: dio, baseUrl: 'https://test.local');

    expect(
      await client.login(studentId: '2026000000', password: 'secret'),
      isA<CaptchaRequired>(),
    );
    await client.getCaptchaChallenge();
    final result = await client.continueLoginWithCaptcha(code: 'wrong');

    expect(result, isA<CaptchaRequired>());
    expect(client.session.state, SessionState.awaitingCaptcha);
    expect(
      requestHeader(adapter.requests[5], 'cookie'),
      contains('JSESSIONID=SESSION_A'),
    );
    client.close(force: true);
  });

  test('取消验证码登录会清理 Cookie 和 pending 状态', () async {
    final keyPair = _newKeyPair();
    final adapter = QueuedHttpAdapter([
      const QueuedHttpResponse(
        statusCode: 200,
        body: '<input id="csrftoken" value="CSRF_A">',
        headers: {
          'set-cookie': ['JSESSIONID=SESSION_A; Path=/'],
        },
      ),
      QueuedHttpResponse(
        statusCode: 200,
        body: _publicKeyBody(keyPair.publicKey),
      ),
      const QueuedHttpResponse(
        statusCode: 200,
        body: '<script>alert("请输入验证码");</script>',
      ),
    ]);
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final jar = CookieJar();
    final client = JiaowuClient(
      dio: dio,
      baseUrl: 'https://test.local',
      cookieJar: jar,
    );

    await client.login(studentId: '2026000000', password: 'secret');
    expect(client.session.state, SessionState.awaitingCaptcha);
    await client.cancelPendingLogin();

    expect(client.session.state, SessionState.unauthenticated);
    expect(await jar.loadForRequest(Uri.parse('https://test.local/')), isEmpty);
    expect(
      await client.continueLoginWithCaptcha(code: 'A7k2'),
      isA<CaptchaExpired>(),
    );
    client.close(force: true);
  });
}

String _publicKeyBody(RSAPublicKey publicKey) {
  return jsonEncode({
    'modulus': base64.encode(_toUnsignedBytes(publicKey.modulus!)),
    'exponent': base64.encode(_toUnsignedBytes(publicKey.publicExponent!)),
  });
}

AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> _newKeyPair() {
  final random = FortunaRandom()
    ..seed(
      KeyParameter(Uint8List.fromList(List<int>.generate(32, (i) => i + 11))),
    );
  final generator = RSAKeyGenerator()
    ..init(
      ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.from(65537), 1024, 12),
        random,
      ),
    );
  final pair = generator.generateKeyPair();
  return AsymmetricKeyPair(
    pair.publicKey as RSAPublicKey,
    pair.privateKey as RSAPrivateKey,
  );
}

Uint8List _toUnsignedBytes(BigInt value) {
  final bytes = <int>[];
  var current = value;
  while (current > BigInt.zero) {
    bytes.add((current & BigInt.from(255)).toInt());
    current >>= 8;
  }
  return Uint8List.fromList(bytes.reversed.toList());
}
