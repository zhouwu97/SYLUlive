import 'dart:convert';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/asymmetric/pkcs1.dart';
import 'package:pointycastle/asymmetric/rsa.dart';
import 'package:pointycastle/key_generators/api.dart';
import 'package:pointycastle/key_generators/rsa_key_generator.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:test/test.dart';

import '../helpers/queued_http_adapter.dart';

void main() {
  test('登录链路共享 CookieJar，并在 302 后通过学生信息探活', () async {
    final keyPair = _newKeyPair();
    final publicKey = keyPair.publicKey;
    final privateKey = keyPair.privateKey;
    final adapter = QueuedHttpAdapter([
      const QueuedHttpResponse(
        statusCode: 200,
        body:
            '<form><input id="csrftoken" name="csrftoken" value="TEST_CSRF"></form>',
        headers: {
          'set-cookie': ['route=TEST_ROUTE; Path=/'],
          'content-type': ['text/html'],
        },
      ),
      QueuedHttpResponse(
        statusCode: 200,
        body: jsonEncode({
          'modulus': base64.encode(_toUnsignedBytes(publicKey.modulus!)),
          'exponent':
              base64.encode(_toUnsignedBytes(publicKey.publicExponent!)),
        }),
        headers: const {
          'content-type': ['application/json']
        },
      ),
      const QueuedHttpResponse(
        statusCode: 302,
        body: '',
        headers: {
          'location': ['/xtgl/index_initMenu.html'],
          'set-cookie': ['JSESSIONID=TEST_SESSION; Path=/'],
        },
      ),
      const QueuedHttpResponse(
        statusCode: 200,
        body: '<div id="col_xm"><p>张三</p></div>',
      ),
    ]);
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final client = JiaowuClient(
      baseUrl: 'https://test.local',
      dio: dio,
      cookieJar: CookieJar(),
    );

    final result = await client.login(
      studentId: '2026000000',
      password: '校园密码-测试',
    );

    expect(result, isA<LoginSuccess>());
    final success = result as LoginSuccess;
    expect(success.cookieNames, containsAll(['route', 'JSESSIONID']));
    expect(client.session.state, SessionState.authenticated);
    expect(adapter.requests.length, 4);
    expect(
      requestHeader(adapter.requests[3], 'cookie'),
      contains('JSESSIONID=TEST_SESSION'),
    );

    final loginData = adapter.requests[2].data as Map<dynamic, dynamic>;
    expect(loginData['csrftoken'], 'TEST_CSRF');
    expect(loginData['language'], 'zh_CN');
    expect(loginData['yhm'], '2026000000');
    expect(loginData['mm'], isNot('校园密码-测试'));

    final decryptor = PKCS1Encoding(RSAEngine())
      ..init(false, PrivateKeyParameter<RSAPrivateKey>(privateKey));
    expect(
      utf8.decode(decryptor.process(base64.decode(loginData['mm'] as String))),
      '校园密码-测试',
    );
    client.close(force: true);
  });

  test('登录响应明确提示账号密码错误时返回 InvalidCredentials', () async {
    final keyPair = _newKeyPair();
    final publicKey = keyPair.publicKey;
    final adapter = QueuedHttpAdapter([
      const QueuedHttpResponse(
        statusCode: 200,
        body: '<input id="csrftoken" name="csrftoken" value="TEST_CSRF">',
      ),
      QueuedHttpResponse(
        statusCode: 200,
        body: jsonEncode({
          'modulus': base64.encode(_toUnsignedBytes(publicKey.modulus!)),
          'exponent':
              base64.encode(_toUnsignedBytes(publicKey.publicExponent!)),
        }),
      ),
      const QueuedHttpResponse(
        statusCode: 200,
        body: '<script>alert("用户名或密码错误");</script>',
      ),
    ]);
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
      ..httpClientAdapter = adapter;
    final client = JiaowuClient(
      baseUrl: 'https://test.local',
      dio: dio,
      cookieJar: CookieJar(),
    );

    final result = await client.login(
      studentId: '2026000000',
      password: 'bad-password',
    );

    expect(result, isA<InvalidCredentials>());
    expect(client.session.state, SessionState.unauthenticated);
    client.close(force: true);
  });
}

AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> _newKeyPair() {
  final random = FortunaRandom()
    ..seed(KeyParameter(
        Uint8List.fromList(List<int>.generate(32, (i) => i + 11))));
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
