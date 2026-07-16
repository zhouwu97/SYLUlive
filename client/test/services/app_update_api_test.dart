import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/app_update_info.dart';
import 'package:shenliyuan/services/app_update_api.dart';

void main() {
  /// 构造一个 mock Dio，拦截指定路径返回伪造响应。
  Dio mockDio({
    required Map<String, dynamic> Function(RequestOptions) responder,
    int? statusCode,
  }) {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.com/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final response = responder(options);
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: statusCode ?? 200,
              data: response,
            ),
          );
        },
      ),
    );
    return dio;
  }

  const shaHex =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  Map<String, dynamic> requiredResponse() => {
        'update_available': true,
        'update_type': 'required',
        'current_version_name': '1.6.1',
        'current_version_code': 1601,
        'latest_version_name': '1.6.2',
        'latest_version_code': 1602,
        'minimum_supported_version_code': 1602,
        'title': '沈理校园 1.6.2',
        'changelog': '修复课表',
        'file_size': 1024,
        'sha256': shaHex,
        'download_url': '/api/app/releases/12/download',
        'published_at': '2026-07-16T10:00:00Z',
        'check_after_seconds': 21600,
      };

  group('AppUpdateApi.checkUpdate 成功路径', () {
    test('200 + 合法 JSON 返回 AppUpdateInfo', () async {
      final api = AppUpdateApi(
        dio: mockDio(responder: (_) => requiredResponse()),
      );
      final info = await api.checkUpdate(
        platform: 'android',
        channel: 'stable',
        versionName: '1.6.1',
        versionCode: 1601,
      );
      expect(info.updateType, AppUpdateType.required);
      expect(info.latestVersionCode, 1602);
      expect(info.downloadUrl, contains('/api/app/releases/12/download'));
    });

    test('请求 query 携带 platform/channel/version_code', () async {
      RequestOptions? captured;
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured = options;
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: requiredResponse(),
              ),
            );
          },
        ),
      );
      final api = AppUpdateApi(dio: dio);
      await api.checkUpdate(
        platform: 'android',
        channel: 'stable',
        versionName: '1.6.1',
        versionCode: 1601,
      );
      expect(captured, isNotNull);
      expect(captured!.path, '/app/update');
      expect(captured!.queryParameters['platform'], 'android');
      expect(captured!.queryParameters['channel'], 'stable');
      expect(captured!.queryParameters['version_code'], '1601');
      expect(captured!.headers['X-App-Version-Code'], '1601');
    });

    test('无更新响应也可解析', () async {
      final api = AppUpdateApi(
        dio: mockDio(
          responder: (_) => {
            'update_available': false,
            'update_type': 'none',
            'current_version_name': '1.6.2',
            'current_version_code': 1602,
            'latest_version_name': '1.6.2',
            'latest_version_code': 1602,
            'minimum_supported_version_code': 1601,
          },
        ),
      );
      final info = await api.checkUpdate(
        platform: 'android',
        channel: 'stable',
        versionName: '1.6.2',
        versionCode: 1602,
      );
      expect(info.updateAvailable, isFalse);
      expect(info.updateType, AppUpdateType.none);
    });
  });

  group('AppUpdateApi.checkUpdate 入参校验', () {
    final api = AppUpdateApi(dio: mockDio(responder: (_) => requiredResponse()));

    test('空 platform 抛 AppUpdateApiException', () {
      expect(
        () => api.checkUpdate(
            platform: '', channel: 'stable', versionName: '1.6.1', versionCode: 1),
        throwsA(isA<AppUpdateApiException>()),
      );
    });
    test('空 channel 抛', () {
      expect(
        () => api.checkUpdate(
            platform: 'android', channel: '', versionName: '1.6.1', versionCode: 1),
        throwsA(isA<AppUpdateApiException>()),
      );
    });
    test('空 version_name 抛', () {
      expect(
        () => api.checkUpdate(
            platform: 'android', channel: 'stable', versionName: '', versionCode: 1),
        throwsA(isA<AppUpdateApiException>()),
      );
    });
    test('version_code <= 0 抛', () {
      expect(
        () => api.checkUpdate(
            platform: 'android',
            channel: 'stable',
            versionName: '1.6.1',
            versionCode: 0),
        throwsA(isA<AppUpdateApiException>()),
      );
    });
  });

  group('AppUpdateApi.checkUpdate 错误处理', () {
    test('非 200 响应抛 AppUpdateApiException', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 503,
                data: {'error': 'temporarily unavailable'},
              ),
            );
          },
        ),
      );
      final api = AppUpdateApi(dio: dio);
      // 由于 validateStatus 默认会收到 503 抛 DioException，这里改放宽校验。
      // 使用注入宽松 validateStatus 的 dio 模拟"非 200 但 200 路径已被放过"。
      final dioRelaxed = Dio(BaseOptions(
        baseUrl: 'https://example.com/api',
        validateStatus: (_) => true,
      ));
      dioRelaxed.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 503,
                data: {'error': 'temporarily unavailable'},
              ),
            );
          },
        ),
      );
      final apiRelaxed = AppUpdateApi(dio: dioRelaxed);
      await expectLater(
        apiRelaxed.checkUpdate(
          platform: 'android',
          channel: 'stable',
          versionName: '1.6.1',
          versionCode: 1601,
        ),
        throwsA(isA<AppUpdateApiException>()),
      );
      // 第一个 dio（默认 validateStatus）会因 503 直接 DioException；
      // 这样验证两类用户的路径都被覆盖。
      await expectLater(
        api.checkUpdate(
          platform: 'android',
          channel: 'stable',
          versionName: '1.6.1',
          versionCode: 1601,
        ),
        throwsA(isA<AppUpdateApiException>()),
      );
    });

    test('非 Map 响应抛 protocol 错误', () async {
      final dio = Dio(BaseOptions(
        baseUrl: 'https://example.com/api',
        validateStatus: (_) => true,
      ));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: 'not-a-map',
              ),
            );
          },
        ),
      );
      final api = AppUpdateApi(dio: dio);
      await expectLater(
        api.checkUpdate(
          platform: 'android',
          channel: 'stable',
          versionName: '1.6.1',
          versionCode: 1601,
        ),
        throwsA(
          isA<AppUpdateApiException>()
              .having((e) => e.kind, 'kind', AppUpdateApiErrorKind.protocol),
        ),
      );
    });

    test('JSON 字段非法抛 protocol 错误并带原始消息', () async {
      final dio = Dio(BaseOptions(
        baseUrl: 'https://example.com/api',
        validateStatus: (_) => true,
      ));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            // 服务端 200 但 sha256 缺失 — 不能沉默放行。
            final broken = requiredResponse()..remove('sha256');
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: broken,
              ),
            );
          },
        ),
      );
      final api = AppUpdateApi(dio: dio);
      await expectLater(
        api.checkUpdate(
          platform: 'android',
          channel: 'stable',
          versionName: '1.6.1',
          versionCode: 1601,
        ),
        throwsA(
          isA<AppUpdateApiException>()
              .having((e) => e.kind, 'kind', AppUpdateApiErrorKind.protocol)
              .having((e) => e.message, 'message', contains('sha256')),
        ),
      );
    });

    test('连接错误分类为 network', () async {
      final dio = Dio(BaseOptions(
        baseUrl: 'https://example.com/api',
        validateStatus: (_) => true,
        connectTimeout: const Duration(milliseconds: 50),
      ));
      // 指向一个根本不可能连通的端口，触发连接错误/
      // 简单 mock：用 interceptor 直接 reject 抛 DioException。
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                message: 'mock network down',
              ),
            );
          },
        ),
      );
      final api = AppUpdateApi(dio: dio);
      await expectLater(
        api.checkUpdate(
          platform: 'android',
          channel: 'stable',
          versionName: '1.6.1',
          versionCode: 1601,
        ),
        throwsA(
          isA<AppUpdateApiException>()
              .having((e) => e.kind, 'kind', AppUpdateApiErrorKind.network),
        ),
      );
    });

    test('5xx badResponse 分类为 server', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            // 直接 reject 为 badResponse DioException，模拟 dio 默认
            // validateStatus 行为下 5xx 的处理路径。
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: Response(
                  requestOptions: options,
                  statusCode: 503,
                  data: {'error': 'unavailable'},
                ),
              ),
            );
          },
        ),
      );
      final api = AppUpdateApi(dio: dio);
      await expectLater(
        api.checkUpdate(
          platform: 'android',
          channel: 'stable',
          versionName: '1.6.1',
          versionCode: 1601,
        ),
        throwsA(
          isA<AppUpdateApiException>()
              .having((e) => e.kind, 'kind', AppUpdateApiErrorKind.server),
        ),
      );
    });
  });
}