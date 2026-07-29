import 'ai_endpoint_policy.dart';
import 'ai_model_provider.dart';

/// 集中管理第三方模型协议的端点、鉴权和自动选择规则。
class AIWireApiPolicy {
  const AIWireApiPolicy._();

  static const String anthropicVersion = '2023-06-01';

  static OpenAIWireApi preferredAutoApi(Uri endpoint) {
    final host = endpoint.host.toLowerCase();
    if (host == 'api.anthropic.com') {
      return OpenAIWireApi.anthropicMessages;
    }
    if (host == 'api.deepseek.com') {
      return OpenAIWireApi.chatCompletions;
    }
    return OpenAIWireApi.responses;
  }

  static List<OpenAIWireApi> autoCandidates(Uri endpoint) {
    return switch (preferredAutoApi(endpoint)) {
      OpenAIWireApi.anthropicMessages => const <OpenAIWireApi>[
          OpenAIWireApi.anthropicMessages,
        ],
      OpenAIWireApi.chatCompletions => const <OpenAIWireApi>[
          OpenAIWireApi.chatCompletions,
        ],
      OpenAIWireApi.responses => const <OpenAIWireApi>[
          OpenAIWireApi.responses,
          OpenAIWireApi.chatCompletions,
          OpenAIWireApi.anthropicMessages,
        ],
      OpenAIWireApi.auto => throw StateError('自动协议不能作为候选协议'),
    };
  }

  static Uri modelsEndpoint(Uri baseEndpoint, OpenAIWireApi wireApi) {
    if (wireApi == OpenAIWireApi.anthropicMessages) {
      return AIEndpointPolicy.versionedEndpointFor(
        baseEndpoint,
        version: 'v1',
        relativePath: 'models',
      );
    }
    return AIEndpointPolicy.endpointFor(baseEndpoint, 'models');
  }

  static Uri inferenceEndpoint(Uri baseEndpoint, OpenAIWireApi wireApi) {
    return switch (wireApi) {
      OpenAIWireApi.responses =>
        AIEndpointPolicy.endpointFor(baseEndpoint, 'responses'),
      OpenAIWireApi.chatCompletions =>
        AIEndpointPolicy.endpointFor(baseEndpoint, 'chat/completions'),
      OpenAIWireApi.anthropicMessages => AIEndpointPolicy.versionedEndpointFor(
          baseEndpoint,
          version: 'v1',
          relativePath: 'messages',
        ),
      OpenAIWireApi.auto => throw StateError('请求前必须解析自动协议'),
    };
  }

  static Map<String, dynamic> requestHeaders({
    required Uri endpoint,
    required OpenAIWireApi wireApi,
    required String apiKey,
    required bool hasBody,
  }) {
    final headers = <String, dynamic>{
      'Accept': 'application/json',
      if (hasBody) 'Content-Type': 'application/json',
    };
    if (wireApi == OpenAIWireApi.anthropicMessages) {
      headers['x-api-key'] = apiKey;
      headers['anthropic-version'] = anthropicVersion;
      // 非官方兼容网关常沿用 Bearer 鉴权；同一密钥只发送到用户配置的主机。
      if (endpoint.host.toLowerCase() != 'api.anthropic.com') {
        headers['Authorization'] = 'Bearer $apiKey';
      }
    } else {
      headers['Authorization'] = 'Bearer $apiKey';
    }
    return headers;
  }
}
