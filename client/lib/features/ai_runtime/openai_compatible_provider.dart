import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'ai_endpoint_policy.dart';
import 'ai_model_provider.dart';
import 'ai_wire_api_policy.dart';

/// 第三方模型兼容实现，仅允许非流式普通文本聊天。
class OpenAICompatibleProvider implements AIModelProvider {
  OpenAICompatibleProvider({
    required AIModelProviderConfig config,
    required String apiKey,
    Dio? dio,
  })  : _config = config,
        _apiKey = apiKey.trim(),
        _baseEndpoint = AIEndpointPolicy.parseBaseEndpoint(config.endpoint),
        _dio = _withDefaultTimeouts(dio ?? Dio());

  static Dio createDio() => _withDefaultTimeouts(Dio());

  static Dio _withDefaultTimeouts(Dio dio) {
    dio.options.connectTimeout ??= const Duration(seconds: 10);
    dio.options.sendTimeout ??= const Duration(seconds: 15);
    dio.options.receiveTimeout ??= const Duration(seconds: 60);
    return dio;
  }

  final AIModelProviderConfig _config;
  final String _apiKey;
  final Uri _baseEndpoint;
  final Dio _dio;
  CancelToken? _activeCancelToken;

  @override
  AIModelProviderKind get kind => AIModelProviderKind.openAICompatible;

  @override
  String get displayName => kind.displayName;

  @override
  Future<AIModelCapabilities> discoverCapabilities() async {
    _ensureApiKey();
    final wireApi = _resolvedWireApi;
    final response = await _request(
      AIWireApiPolicy.modelsEndpoint(_baseEndpoint, wireApi),
      method: 'GET',
      wireApi: wireApi,
    );
    _expectSuccess(response, fallback: '读取模型列表失败');
    final data = _map(response.data, '模型服务返回格式错误');
    final rawModels = data['data'];
    final models = rawModels is List
        ? rawModels
            .whereType<Map>()
            .map((item) => item['id']?.toString().trim() ?? '')
            .where((model) => model.isNotEmpty)
            .toSet()
            .toList()
        : <String>[];
    models.sort();
    // /models 只证明模型列表可读取，不能证明聊天、流式或工具调用可用。
    return AIModelCapabilities(
      chatAvailability: AIModelChatAvailability.unknown,
      models: models,
    );
  }

  @override
  Future<AIModelChatResponse> complete(
      List<AIModelChatMessage> messages) async {
    _ensureApiKey();
    final model = _config.model.trim();
    if (model.isEmpty) {
      throw const AIModelProviderException('请先选择或填写模型名称');
    }
    final wireApi = _resolvedWireApi;
    final payload = _completionPayload(wireApi, model, messages);
    final response = await _request(
      AIWireApiPolicy.inferenceEndpoint(_baseEndpoint, wireApi),
      method: 'POST',
      wireApi: wireApi,
      data: payload,
    );
    _expectSuccess(response, fallback: '普通聊天请求失败');
    final data = _map(response.data, '模型服务返回格式错误');
    final content = switch (wireApi) {
      OpenAIWireApi.responses => _responsesText(data),
      OpenAIWireApi.chatCompletions => _chatCompletionText(data),
      OpenAIWireApi.anthropicMessages => _messageContent(data['content']),
      OpenAIWireApi.auto => throw StateError('请求前必须解析自动协议'),
    };
    if (content.isEmpty) {
      throw const AIModelProviderException('模型服务没有返回文本内容');
    }
    return AIModelChatResponse(
      content: content,
      model: data['model']?.toString().trim().isEmpty ?? true
          ? model
          : data['model'].toString(),
    );
  }

  Map<String, dynamic> _completionPayload(
    OpenAIWireApi wireApi,
    String model,
    List<AIModelChatMessage> messages,
  ) {
    final serialized =
        messages.map((message) => message.toOpenAIJson()).toList();
    return switch (wireApi) {
      OpenAIWireApi.responses => <String, dynamic>{
          'model': model,
          'stream': false,
          'input': serialized,
        },
      OpenAIWireApi.chatCompletions => <String, dynamic>{
          'model': model,
          'stream': false,
          'tools': const <Object>[],
          'messages': serialized,
        },
      OpenAIWireApi.anthropicMessages => <String, dynamic>{
          'model': model,
          'max_tokens': 4096,
          'stream': false,
          'messages': serialized,
        },
      OpenAIWireApi.auto => throw StateError('请求前必须解析自动协议'),
    };
  }

  String _chatCompletionText(Map<String, dynamic> data) {
    final choices = data['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      throw const AIModelProviderException('模型服务没有返回聊天内容');
    }
    final message = Map<String, dynamic>.from(choices.first as Map)['message'];
    if (message is! Map) {
      throw const AIModelProviderException('模型服务返回的聊天内容格式错误');
    }
    return _messageContent(Map<String, dynamic>.from(message)['content']);
  }

  String _responsesText(Map<String, dynamic> data) {
    final direct = data['output_text'];
    if (direct is String && direct.trim().isNotEmpty) return direct.trim();
    final output = data['output'];
    if (output is! List) return '';
    return output
        .whereType<Map>()
        .where((item) => item['type'] == 'message')
        .map((item) => _messageContent(item['content']))
        .where((text) => text.isNotEmpty)
        .join('\n')
        .trim();
  }

  @override
  Future<void> cancelActiveRequest() async {
    _activeCancelToken?.cancel('client_ai_context_closed');
  }

  Future<Response<dynamic>> _request(
    Uri uri, {
    required String method,
    required OpenAIWireApi wireApi,
    Object? data,
  }) async {
    if (kIsWeb) {
      throw const AIModelProviderException(
        '为保护 API Key，浏览器端不支持第三方模型服务，请使用 App 客户端',
      );
    }
    final cancelToken = CancelToken();
    _activeCancelToken = cancelToken;
    try {
      final response = await _dio.requestUri<dynamic>(
        uri,
        data: data,
        cancelToken: cancelToken,
        options: AIEndpointPolicy.directRequestOptions(
          AIWireApiPolicy.requestHeaders(
            endpoint: _baseEndpoint,
            wireApi: wireApi,
            apiKey: _apiKey,
            hasBody: method == 'POST',
          ),
        ).copyWith(method: method),
      );
      AIEndpointPolicy.ensureDirectResponse(response);
      return response;
    } on AIModelProviderException {
      rethrow;
    } on DioException catch (error) {
      if (error.response != null) {
        throw AIModelProviderException(
          _responseErrorMessage(error.response!, '模型服务请求被拒绝'),
        );
      }
      throw AIModelProviderException(_dioErrorMessage(error));
    } finally {
      if (identical(_activeCancelToken, cancelToken)) {
        _activeCancelToken = null;
      }
    }
  }

  void _ensureApiKey() {
    if (_apiKey.isEmpty) {
      throw const AIModelProviderException('未找到 API Key，请在模型设置中重新保存');
    }
  }

  OpenAIWireApi get _resolvedWireApi {
    if (_config.wireApi != OpenAIWireApi.auto) return _config.wireApi;
    final preferred = AIWireApiPolicy.preferredAutoApi(_baseEndpoint);
    // 普通聊天以兼容面更广的 Chat Completions 为默认值；Tool Calling
    // 模型会单独执行 Responses 优先的协议探测。
    return preferred == OpenAIWireApi.responses
        ? OpenAIWireApi.chatCompletions
        : preferred;
  }

  void _expectSuccess(Response<dynamic> response, {required String fallback}) {
    final status = response.statusCode ?? 0;
    if (status >= 200 && status < 300) return;
    throw AIModelProviderException(_responseErrorMessage(response, fallback));
  }

  String _responseErrorMessage(Response<dynamic> response, String fallback) {
    final data = response.data;
    if (data is Map) {
      final error = data['error'];
      if (error is Map) {
        final message = error['message']?.toString().trim() ?? '';
        if (message.isNotEmpty) return message;
      }
      final message = data['message']?.toString().trim() ?? '';
      if (message.isNotEmpty) return message;
    }
    return response.statusCode == 401 ? 'API Key 无效或已失效' : fallback;
  }

  String _dioErrorMessage(DioException error) {
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout) {
      return '连接模型服务超时';
    }
    if (error.type == DioExceptionType.cancel) return '模型服务请求已取消';
    return '无法连接模型服务，请检查 HTTPS 地址和网络';
  }

  Map<String, dynamic> _map(dynamic value, String errorMessage) {
    if (value is Map) return Map<String, dynamic>.from(value);
    throw AIModelProviderException(errorMessage);
  }

  String _messageContent(dynamic value) {
    if (value is String) return value.trim();
    if (value is! List) return '';
    return value
        .whereType<Map>()
        .map((part) {
          final text = part['text'];
          if (text is String) return text;
          if (text is Map) return text['value']?.toString() ?? '';
          return '';
        })
        .join()
        .trim();
  }
}
