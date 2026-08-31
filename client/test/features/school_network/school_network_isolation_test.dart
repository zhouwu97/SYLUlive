import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/school_network/school_network.dart';

class _QueuedResponse {
  const _QueuedResponse({
    this.statusCode = 200,
    this.data = const <String, dynamic>{'ok': true},
    this.headers = const <String, List<String>>{},
    this.exceptionType,
  });

  final int statusCode;
  final Object? data;
  final Map<String, List<String>> headers;
  final DioExceptionType? exceptionType;
}

/// 记录最终进入传输层的请求，避免只验证调用前的业务参数。
class _RecordingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = <RequestOptions>[];
  final List<_QueuedResponse> responses = <_QueuedResponse>[];

  void enqueue(_QueuedResponse response) => responses.add(response);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    await requestStream?.drain<void>();
    if (responses.isEmpty) {
      throw StateError('缺少预设响应: ${options.method} ${options.uri}');
    }
    final response = responses.removeAt(0);
    if (response.exceptionType != null) {
      throw DioException(
        requestOptions: options,
        type: response.exceptionType!,
        message: '测试网络错误',
      );
    }
    return ResponseBody.fromString(
      jsonEncode(response.data),
      response.statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json'],
        ...response.headers,
      },
    );
  }
}

void main() {
  group('SchoolNetworkPolicy', () {
    final policy = SchoolNetworkPolicy(
      personalHosts: const <String>['personal.sylu.test'],
      publicHosts: const <String>['public.sylu.test'],
    );

    test('拒绝 HTTP、非允许端口、IP 与不在名单内的主机', () {
      expect(
        () => policy.validatePersonal(
          Uri.parse('http://personal.sylu.test/profile'),
        ),
        throwsA(isA<SchoolNetworkException>()),
      );
      expect(
        () => policy.validatePersonal(
          Uri.parse('https://personal.sylu.test:8443/profile'),
        ),
        throwsA(isA<SchoolNetworkException>()),
      );
      expect(
        () => SchoolNetworkPolicy(
          personalHosts: const <String>['127.0.0.1'],
        ).validatePersonal(Uri.parse('https://127.0.0.1/profile')),
        throwsA(isA<SchoolNetworkException>()),
      );
      expect(
        () => policy.validatePersonal(Uri.parse('https://evil.test/profile')),
        throwsA(isA<SchoolNetworkException>()),
      );
    });
  });

  group('凭据隔离', () {
    test('学校 Cookie 不进入 App API，App JWT 只进入 App API', () async {
      final adapter = _RecordingAdapter()
        ..enqueue(const _QueuedResponse(data: <String, dynamic>{'id': 1}));
      final client = AppApiClient(
        httpClientAdapter: adapter,
        baseUrl: Uri.parse('https://api.sylulive.test'),
      );

      await expectLater(
        client.get<Map<String, dynamic>>(
          '/me',
          appJwt: 'SECRET_APP_JWT',
          options: Options(
            headers: <String, dynamic>{
              'Cookie': 'session=SECRET_SCHOOL_COOKIE',
            },
          ),
        ),
        throwsA(isA<SchoolNetworkException>()),
      );
      expect(adapter.requests, isEmpty);

      await client.get<Map<String, dynamic>>(
        '/me',
        appJwt: 'SECRET_APP_JWT',
      );
      expect(adapter.requests, hasLength(1));
      expect(
        adapter.requests.single.headers['Authorization'],
        'Bearer SECRET_APP_JWT',
      );
      expect(
        adapter.requests.single.headers.values.join(' '),
        isNot(contains('SECRET_SCHOOL_COOKIE')),
      );
    });

    test('App API 使用固定 baseUrl 且拒绝外部绝对 URL', () async {
      final adapter = _RecordingAdapter()
        ..enqueue(const _QueuedResponse(data: <String, dynamic>{'id': 1}));
      final client = AppApiClient(
        baseUrl: Uri.parse('https://api.sylulive.test/api/'),
        httpClientAdapter: adapter,
      );

      await client.get<Map<String, dynamic>>(
        'me',
        appJwt: 'SECRET_APP_JWT',
      );
      expect(adapter.requests.single.uri.toString(),
          'https://api.sylulive.test/api/me');

      await expectLater(
        client.get<Map<String, dynamic>>(
          'https://evil.test/steal',
          appJwt: 'SECRET_APP_JWT',
        ),
        throwsA(isA<SchoolNetworkException>()),
      );
      expect(adapter.requests, hasLength(1));
    });

    test('App JWT 不进入学校个人客户端', () async {
      final adapter = _RecordingAdapter();
      final client = SchoolPersonalClient(
        policy: SchoolNetworkPolicy(
          personalHosts: const <String>['personal.sylu.test'],
        ),
        httpClientAdapter: adapter,
        retryDelay: Duration.zero,
      );

      await expectLater(
        client.get<Map<String, dynamic>>(
          Uri.parse('https://personal.sylu.test/profile'),
          headers: const <String, dynamic>{
            'Authorization': 'Bearer SECRET_APP_JWT',
          },
        ),
        throwsA(isA<SchoolNetworkException>()),
      );
      expect(adapter.requests, isEmpty);
    });

    test('公开学校客户端拒绝 JWT 与 Cookie', () async {
      final adapter = _RecordingAdapter();
      final client = SchoolPublicClient(
        policy: SchoolNetworkPolicy(
          personalHosts: const <String>['personal.sylu.test'],
          publicHosts: const <String>['public.sylu.test'],
        ),
        httpClientAdapter: adapter,
      );

      for (final headers in <Map<String, dynamic>>[
        const <String, dynamic>{
          'Authorization': 'Bearer SECRET_APP_JWT',
        },
        const <String, dynamic>{
          'Cookie': 'session=SECRET_SCHOOL_COOKIE',
        },
      ]) {
        await expectLater(
          client.getJson<Map<String, dynamic>>(
            Uri.parse('https://public.sylu.test/news'),
            headers: headers,
          ),
          throwsA(isA<SchoolNetworkException>()),
        );
      }
      expect(adapter.requests, isEmpty);
    });

    test('共享传输适配器不会让个人 Cookie 进入 App API 或公开学校请求', () async {
      final adapter = _RecordingAdapter()
        ..enqueue(const _QueuedResponse())
        ..enqueue(const _QueuedResponse())
        ..enqueue(const _QueuedResponse());
      final personalUri = Uri.parse('https://personal.sylu.test/profile');
      final cookieJar = CookieJar();
      await cookieJar.saveFromResponse(
        personalUri,
        <Cookie>[Cookie('session', 'SECRET_SCHOOL_COOKIE')],
      );
      final policy = SchoolNetworkPolicy(
        personalHosts: const <String>['personal.sylu.test'],
        publicHosts: const <String>['public.sylu.test'],
      );
      final personal = SchoolPersonalClient(
        policy: policy,
        cookieJar: cookieJar,
        httpClientAdapter: adapter,
      );
      final app = AppApiClient(
        baseUrl: Uri.parse('https://api.sylulive.test'),
        httpClientAdapter: adapter,
      );
      final schoolPublic = SchoolPublicClient(
        policy: policy,
        httpClientAdapter: adapter,
      );

      await personal.get<Map<String, dynamic>>(personalUri);
      await app.get<Map<String, dynamic>>('/me', appJwt: 'SECRET_APP_JWT');
      await schoolPublic.getJson<Map<String, dynamic>>(
        Uri.parse('https://public.sylu.test/news'),
      );

      expect(adapter.requests, hasLength(3));
      expect(
        adapter.requests[0].headers.values.join(' '),
        contains('SECRET_SCHOOL_COOKIE'),
      );
      expect(
        adapter.requests[1].headers.values.join(' '),
        isNot(contains('SECRET_SCHOOL_COOKIE')),
      );
      expect(
        adapter.requests[2].headers.values.join(' '),
        isNot(contains('SECRET_SCHOOL_COOKIE')),
      );
      expect(
        adapter.requests[2].headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('authorization')),
      );
    });
  });

  group('重定向与重试', () {
    test('每一跳重定向都重新校验主机', () async {
      final adapter = _RecordingAdapter()
        ..enqueue(
          const _QueuedResponse(
            statusCode: 302,
            headers: <String, List<String>>{
              'location': <String>['https://evil.test/steal'],
            },
          ),
        );
      final client = SchoolPersonalClient(
        policy: SchoolNetworkPolicy(
          personalHosts: const <String>['personal.sylu.test'],
        ),
        httpClientAdapter: adapter,
        retryDelay: Duration.zero,
      );

      await expectLater(
        client.get<dynamic>(
          Uri.parse('https://personal.sylu.test/profile'),
        ),
        throwsA(isA<SchoolNetworkException>()),
      );
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.uri.host, 'personal.sylu.test');
    });

    test('无凭据 GET 有限重试，POST 网络失败不自动重试', () async {
      final getAdapter = _RecordingAdapter()
        ..enqueue(
          const _QueuedResponse(
            exceptionType: DioExceptionType.connectionError,
          ),
        )
        ..enqueue(
          const _QueuedResponse(data: <String, dynamic>{'ok': true}),
        );
      final policy = SchoolNetworkPolicy(
        personalHosts: const <String>['personal.sylu.test'],
      );
      final getClient = SchoolPersonalClient(
        policy: policy,
        httpClientAdapter: getAdapter,
        maxRetries: 2,
        retryDelay: Duration.zero,
      );

      final response = await getClient.get<Map<String, dynamic>>(
        Uri.parse('https://personal.sylu.test/profile'),
        allowRetry: true,
      );
      expect(response.data['ok'], isTrue);
      expect(getAdapter.requests, hasLength(2));

      final postAdapter = _RecordingAdapter()
        ..enqueue(
          const _QueuedResponse(
            exceptionType: DioExceptionType.connectionError,
          ),
        )
        ..enqueue(
          const _QueuedResponse(data: <String, dynamic>{'ok': true}),
        );
      final postClient = SchoolPersonalClient(
        policy: policy,
        httpClientAdapter: postAdapter,
        maxRetries: 2,
        retryDelay: Duration.zero,
      );

      await expectLater(
        postClient.post<Map<String, dynamic>>(
          Uri.parse('https://personal.sylu.test/login'),
          data: const <String, dynamic>{'username': 'test'},
        ),
        throwsA(isA<SchoolNetworkException>()),
      );
      expect(postAdapter.requests, hasLength(1));
    });

    test('即使显式允许，带学校 Cookie 的 GET 也不自动重试', () async {
      final uri = Uri.parse('https://personal.sylu.test/profile');
      final cookieJar = CookieJar();
      await cookieJar.saveFromResponse(
        uri,
        <Cookie>[Cookie('session', 'SECRET_SCHOOL_COOKIE')],
      );
      final adapter = _RecordingAdapter()
        ..enqueue(
          const _QueuedResponse(
            exceptionType: DioExceptionType.connectionError,
          ),
        )
        ..enqueue(
          const _QueuedResponse(data: <String, dynamic>{'ok': true}),
        );
      final client = SchoolPersonalClient(
        policy: SchoolNetworkPolicy(
          personalHosts: const <String>['personal.sylu.test'],
        ),
        httpClientAdapter: adapter,
        cookieJar: cookieJar,
        maxRetries: 2,
        retryDelay: Duration.zero,
      );

      await expectLater(
        client.get<Map<String, dynamic>>(uri, allowRetry: true),
        throwsA(isA<SchoolNetworkException>()),
      );
      expect(adapter.requests, hasLength(1));
      expect(
        adapter.requests.single.headers.values.join(' '),
        contains('SECRET_SCHOOL_COOKIE'),
      );
    });
  });
}
