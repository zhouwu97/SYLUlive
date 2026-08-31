import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';

import 'school_network_policy.dart';

/// 公共的响应封装，避免把 Dio 实例泄露到上层业务。
class SchoolHttpResponse<T> {
  const SchoolHttpResponse({
    required this.statusCode,
    required this.data,
    required this.uri,
    this.headers = const <String, List<String>>{},
  });

  final int statusCode;
  final T data;
  final Uri uri;
  final Map<String, List<String>> headers;

  String? header(String name) {
    final values = headers[name.toLowerCase()];
    return values == null || values.isEmpty ? null : values.join(', ');
  }
}

/// App API 的最小客户端：只允许 App JWT，不接触学校 Cookie。
class AppApiClient {
  AppApiClient({
    HttpClientAdapter? httpClientAdapter,
    this.baseUrl,
    Duration timeout = const Duration(seconds: 20),
  }) : _dio = _newDio(timeout, baseUrl) {
    if (httpClientAdapter != null) {
      _dio.httpClientAdapter = httpClientAdapter;
    }
  }

  final Dio _dio;
  final Uri? baseUrl;

  Future<SchoolHttpResponse<T>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    String? appJwt,
    Options? options,
  }) {
    return _request<T>(
      method: 'GET',
      path: path,
      queryParameters: queryParameters,
      appJwt: appJwt,
      options: options,
    );
  }

  Future<SchoolHttpResponse<T>> post<T>(
    String path, {
    Object? data,
    String? appJwt,
    Options? options,
  }) {
    return _request<T>(
      method: 'POST',
      path: path,
      data: data,
      appJwt: appJwt,
      options: options,
    );
  }

  Future<SchoolHttpResponse<T>> _request<T>({
    required String method,
    required String path,
    Object? data,
    Map<String, dynamic>? queryParameters,
    String? appJwt,
    Options? options,
  }) async {
    _validateRelativePath(path);
    final headers = <String, dynamic>{...?options?.headers};
    if (headers.keys.any((key) => key.toLowerCase() == 'cookie')) {
      throw const SchoolNetworkException('App API 禁止携带学校 Cookie');
    }
    headers.removeWhere((key, _) => key.toLowerCase() == 'cookie');
    final normalizedJwt = appJwt?.trim();
    if (normalizedJwt != null && normalizedJwt.isNotEmpty) {
      headers['Authorization'] = 'Bearer $normalizedJwt';
    }
    final requestOptions = (options ?? Options()).copyWith(
      method: method,
      headers: headers,
      followRedirects: false,
      maxRedirects: 0,
    );
    try {
      final response = await _dio.request<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: requestOptions,
      );
      return _wrap(response);
    } on DioException catch (error) {
      throw SchoolNetworkException(
        'App API 请求失败',
        statusCode: error.response?.statusCode,
      );
    }
  }

  SchoolHttpResponse<T> _wrap<T>(Response<T> response) {
    final status = response.statusCode ?? 0;
    if (status >= 300 && status < 400) {
      throw const SchoolNetworkException('App API 禁止未校验的重定向');
    }
    return SchoolHttpResponse<T>(
      statusCode: status,
      data: response.data as T,
      uri: response.realUri,
      headers: _headers(response.headers),
    );
  }

  static void _validateRelativePath(String path) {
    final normalized = path.trim();
    final uri = Uri.tryParse(normalized);
    if (normalized.isEmpty ||
        uri == null ||
        uri.hasScheme ||
        uri.hasAuthority ||
        normalized.startsWith('//')) {
      throw const SchoolNetworkException('App API 仅允许相对请求路径');
    }
  }

  static Dio _newDio(Duration timeout, Uri? baseUrl) => Dio(
        BaseOptions(
          baseUrl: baseUrl?.toString() ?? '',
          connectTimeout: timeout,
          sendTimeout: timeout,
          receiveTimeout: timeout,
        ),
      );

  static Map<String, List<String>> _headers(Headers headers) => {
        for (final entry in headers.map.entries)
          entry.key.toLowerCase(): List<String>.from(entry.value),
      };

  Future<void> close() async => _dio.close(force: true);
}

/// 学校个人客户端。CookieJar 独立于 App API 与公开客户端。
class SchoolPersonalClient {
  SchoolPersonalClient({
    required this.policy,
    HttpClientAdapter? httpClientAdapter,
    CookieJar? cookieJar,
    Duration timeout = const Duration(seconds: 20),
    this.maxRetries = 2,
    Duration retryDelay = const Duration(milliseconds: 100),
  })  : _dio = _newDio(timeout),
        cookieJar = cookieJar ?? CookieJar(),
        _retryDelay = retryDelay {
    if (httpClientAdapter != null) {
      _dio.httpClientAdapter = httpClientAdapter;
    }
    // 每个实例建立自己的 CookieManager；绝不复用 App API 的拦截器或 Jar。
    _dio.interceptors.add(CookieManager(this.cookieJar));
  }

  final SchoolNetworkPolicy policy;
  final Dio _dio;
  final CookieJar cookieJar;
  final int maxRetries;
  final Duration _retryDelay;

  /// 读取请求允许有限重试；调用方不能借此重试登录或凭据请求。
  Future<SchoolHttpResponse<T>> get<T>(
    Uri uri, {
    Map<String, dynamic>? headers,
    ResponseType? responseType,
    bool allowRetry = false,
  }) =>
      _request<T>(
        method: 'GET',
        uri: uri,
        headers: headers,
        responseType: responseType,
        allowRetry: allowRetry,
        credentialBearing: false,
      );

  Future<SchoolHttpResponse<T>> head<T>(Uri uri,
          {Map<String, dynamic>? headers, bool allowRetry = false}) =>
      _request<T>(
        method: 'HEAD',
        uri: uri,
        headers: headers,
        allowRetry: allowRetry,
        credentialBearing: false,
      );

  /// 登录、验证码和携带 Cookie 的写请求默认禁止重试。
  Future<SchoolHttpResponse<T>> post<T>(
    Uri uri, {
    Object? data,
    Map<String, dynamic>? headers,
    ResponseType? responseType,
    bool credentialBearing = true,
  }) =>
      _request<T>(
        method: 'POST',
        uri: uri,
        data: data,
        headers: headers,
        responseType: responseType,
        allowRetry: false,
        credentialBearing: credentialBearing,
      );

  Future<SchoolHttpResponse<T>> _request<T>({
    required String method,
    required Uri uri,
    Object? data,
    Map<String, dynamic>? headers,
    ResponseType? responseType,
    required bool allowRetry,
    required bool credentialBearing,
  }) async {
    var nextUri = policy.validatePersonal(uri);
    var nextMethod = method.toUpperCase();
    var nextData = data;
    var attempts = 0;
    var redirects = 0;

    final safeHeaders = <String, dynamic>{...?headers};
    if (safeHeaders.keys.any((key) => key.toLowerCase() == 'authorization')) {
      throw const SchoolNetworkException('学校请求禁止携带 App JWT');
    }
    // Cookie 只能由本客户端的 CookieManager 注入，不能由业务层跨边界传入。
    safeHeaders.removeWhere((key, _) =>
        key.toLowerCase() == 'authorization' || key.toLowerCase() == 'cookie');

    while (true) {
      try {
        final response = await _dio.request<T>(
          nextUri.toString(),
          data: nextData,
          options: Options(
            method: nextMethod,
            headers: safeHeaders,
            responseType: responseType,
            followRedirects: false,
            maxRedirects: 0,
            validateStatus: (status) =>
                status != null && status >= 200 && status < 400,
          ),
        );
        final status = response.statusCode ?? 0;
        if (status >= 300 && status < 400) {
          if (redirects++ >= policy.maxRedirects) {
            throw const SchoolNetworkException('学校请求重定向次数过多');
          }
          final location = response.headers.value('location');
          if (location == null || location.trim().isEmpty) {
            throw const SchoolNetworkException('学校响应缺少重定向地址');
          }
          final redirected = policy.validatePersonal(
            nextUri.resolve(location.trim()),
          );
          final redirectStatus = status;
          nextUri = redirected;
          if (redirectStatus == 301 ||
              redirectStatus == 302 ||
              redirectStatus == 303) {
            nextMethod = 'GET';
            nextData = null;
          }
          continue;
        }
        return SchoolHttpResponse<T>(
          statusCode: status,
          data: response.data as T,
          uri: response.realUri,
          headers: AppApiClient._headers(response.headers),
        );
      } on DioException catch (error) {
        final hasCookies = (await cookieJar.loadForRequest(nextUri)).isNotEmpty;
        final retryable = allowRetry &&
            !credentialBearing &&
            !hasCookies &&
            (nextMethod == 'GET' || nextMethod == 'HEAD') &&
            _isRetryable(error);
        if (!retryable || attempts >= maxRetries) {
          throw SchoolNetworkException(
            '学校请求失败',
            statusCode: error.response?.statusCode,
          );
        }
        attempts++;
        if (_retryDelay > Duration.zero) {
          await Future<void>.delayed(_retryDelay * attempts);
        }
      }
    }
  }

  bool _isRetryable(DioException error) {
    final status = error.response?.statusCode;
    if (status != null) {
      return status == 408 || status == 425 || status == 429 || status >= 500;
    }
    return error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.unknown;
  }

  static Dio _newDio(Duration timeout) => Dio(
        BaseOptions(
          connectTimeout: timeout,
          sendTimeout: timeout,
          receiveTimeout: timeout,
        ),
      );

  Future<void> clearCookies() async => cookieJar.deleteAll();

  Future<void> close() async {
    await clearCookies();
    _dio.close(force: true);
  }
}

/// 学校公开客户端。不安装 CookieManager，不接受 JWT、Cookie 或凭据字段。
class SchoolPublicClient {
  SchoolPublicClient({
    required this.policy,
    HttpClientAdapter? httpClientAdapter,
    Duration timeout = const Duration(seconds: 15),
    LocalSchoolPublicCache? cache,
  })  : _dio = _newDio(timeout),
        cache = cache ?? MemorySchoolPublicCache() {
    if (httpClientAdapter != null) {
      _dio.httpClientAdapter = httpClientAdapter;
    }
  }

  final SchoolNetworkPolicy policy;
  final Dio _dio;
  final LocalSchoolPublicCache cache;

  Future<String> getHtml(Uri uri, {Map<String, dynamic>? headers}) async {
    final key = uri.toString();
    final cached = await cache.read(key);
    if (cached != null) return cached;
    final response =
        await _get(uri, headers: headers, responseType: ResponseType.plain);
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        response.data is! String) {
      throw SchoolNetworkException('学校公开资讯响应无效',
          statusCode: response.statusCode);
    }
    final html = response.data as String;
    await cache.write(key, html);
    return html;
  }

  Future<SchoolHttpResponse<T>> getJson<T>(Uri uri,
      {Map<String, dynamic>? headers}) async {
    final response =
        await _get<T>(uri, headers: headers, responseType: ResponseType.json);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SchoolNetworkException('学校公开数据响应无效',
          statusCode: response.statusCode);
    }
    return response;
  }

  Future<SchoolHttpResponse<T>> _get<T>(
    Uri uri, {
    Map<String, dynamic>? headers,
    ResponseType? responseType,
  }) async {
    final safeHeaders = <String, dynamic>{...?headers};
    if (safeHeaders.keys.any((key) =>
        key.toLowerCase() == 'authorization' ||
        key.toLowerCase() == 'cookie')) {
      throw const SchoolNetworkException('学校公开请求禁止凭据');
    }
    try {
      final validated = policy.validatePublic(uri);
      final response = await _dio.get<T>(
        validated.toString(),
        options: Options(
          headers: safeHeaders,
          responseType: responseType,
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (status) =>
              status != null && status >= 200 && status < 400,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status >= 300 && status < 400) {
        throw const SchoolNetworkException('学校公开请求禁止未校验的重定向');
      }
      return SchoolHttpResponse<T>(
        statusCode: status,
        data: response.data as T,
        uri: response.realUri,
        headers: AppApiClient._headers(response.headers),
      );
    } on DioException catch (error) {
      throw SchoolNetworkException(
        '学校公开请求失败',
        statusCode: error.response?.statusCode,
      );
    }
  }

  static Dio _newDio(Duration timeout) => Dio(
        BaseOptions(
          connectTimeout: timeout,
          sendTimeout: timeout,
          receiveTimeout: timeout,
        ),
      );

  Future<void> close() async => _dio.close(force: true);
}

/// 资讯缓存接口只允许本地实现，不携带任何学校个人凭据。
abstract interface class LocalSchoolPublicCache {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> clear();
}

class MemorySchoolPublicCache implements LocalSchoolPublicCache {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> clear() async => _values.clear();
}
