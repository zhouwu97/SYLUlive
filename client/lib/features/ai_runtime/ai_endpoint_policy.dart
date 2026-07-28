import 'package:dio/dio.dart';

import 'ai_model_provider.dart';

/// 对携带第三方 API Key 的请求执行保守的端点策略。
///
/// 自动跟随重定向可能把 Authorization 头交给未知主机，因此请求一律直连；
/// 用户需要在设置中填写服务商给出的最终 HTTPS 地址。
class AIEndpointPolicy {
  const AIEndpointPolicy._();

  static Uri parseBaseEndpoint(String value) {
    final endpoint = value.trim();
    if (_hasPathTraversal(endpoint)) {
      throw const AIModelProviderException('服务地址不能包含路径跳转');
    }
    final uri = Uri.tryParse(endpoint);
    if (uri == null || !uri.isAbsolute || uri.host.isEmpty) {
      throw const AIModelProviderException('请输入完整的 HTTPS 服务地址');
    }
    if (uri.scheme.toLowerCase() != 'https') {
      throw const AIModelProviderException('模型服务仅允许使用 HTTPS 地址');
    }
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      throw const AIModelProviderException('服务地址不能包含账号、参数或锚点');
    }

    final path = uri.path.isEmpty
        ? '/'
        : uri.path.endsWith('/')
            ? uri.path
            : '${uri.path}/';
    return uri.replace(path: path);
  }

  static bool _hasPathTraversal(String endpoint) {
    final schemeEnd = endpoint.indexOf('://');
    if (schemeEnd < 0) return false;
    final authorityAndPath = endpoint.substring(schemeEnd + 3);
    final queryOrFragment = authorityAndPath.indexOf(RegExp(r'[?#]'));
    final withoutQuery = queryOrFragment < 0
        ? authorityAndPath
        : authorityAndPath.substring(0, queryOrFragment);
    final pathStart = withoutQuery.indexOf('/');
    if (pathStart < 0) return false;
    return withoutQuery.substring(pathStart).split('/').any((segment) {
      try {
        final decoded = Uri.decodeComponent(segment);
        return decoded == '.' || decoded == '..';
      } on FormatException {
        return true;
      }
    });
  }

  static Uri endpointFor(Uri baseEndpoint, String relativePath) {
    final normalizedBase = _isDeepSeekV1Alias(baseEndpoint)
        ? baseEndpoint.replace(path: '/')
        : baseEndpoint;
    return normalizedBase.resolve(relativePath);
  }

  /// 兼容基础地址已经包含协议版本段的配置，避免生成重复的 `/v1/v1`。
  static Uri versionedEndpointFor(
    Uri baseEndpoint, {
    required String version,
    required String relativePath,
  }) {
    final segments = baseEndpoint.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    final path = segments.isNotEmpty && segments.last == version
        ? relativePath
        : '$version/$relativePath';
    return baseEndpoint.resolve(path);
  }

  /// DeepSeek 早期兼容配置常带 `/v1`，当前官方接口以根路径作为基础地址。
  static bool _isDeepSeekV1Alias(Uri endpoint) =>
      endpoint.host.toLowerCase() == 'api.deepseek.com' &&
      (endpoint.path == '/v1' || endpoint.path == '/v1/');

  static Options directRequestOptions(Map<String, dynamic> headers) {
    return Options(
      headers: headers,
      followRedirects: false,
      maxRedirects: 0,
      validateStatus: (status) =>
          status != null && status >= 200 && status < 400,
    );
  }

  static void ensureDirectResponse(Response<dynamic> response) {
    final status = response.statusCode ?? 0;
    if (status >= 300 && status < 400) {
      throw const AIModelProviderException(
        '模型服务发生重定向，请在设置中填写最终 HTTPS 地址',
      );
    }
  }
}
