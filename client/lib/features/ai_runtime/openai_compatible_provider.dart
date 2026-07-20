import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'ai_endpoint_policy.dart';
import 'ai_model_provider.dart';

/// OpenAI Chat Completions 兼容实现，阶段 1 仅允许非流式普通文本聊天。
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
    final response = await _request(
      'models',
      method: 'GET',
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
    final payload = <String, dynamic>{
      'model': model,
      'stream': false,
      'tools': const <Object>[],
      'messages': messages.map((message) => message.toOpenAIJson()).toList(),
    };
    final response = await _request(
      'chat/completions',
      method: 'POST',
      data: payload,
    );
    _expectSuccess(response, fallback: '普通聊天请求失败');
    final data = _map(response.data, '模型服务返回格式错误');
    final choices = data['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      throw const AIModelProviderException('模型服务没有返回聊天内容');
    }
    final message = Map<String, dynamic>.from(choices.first as Map)['message'];
    if (message is! Map) {
      throw const AIModelProviderException('模型服务返回的聊天内容格式错误');
    }
    final content =
        _messageContent(Map<String, dynamic>.from(message)['content']);
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

  @override
  Future<void> cancelActiveRequest() async {
    _activeCancelToken?.cancel('client_ai_context_closed');
  }

  Future<Response<dynamic>> _request(
    String path, {
    required String method,
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
        AIEndpointPolicy.endpointFor(_baseEndpoint, path),
        data: data,
        cancelToken: cancelToken,
        options: AIEndpointPolicy.directRequestOptions(<String, dynamic>{
          'Authorization': 'Bearer $_apiKey',
          'Accept': 'application/json',
          if (method == 'POST') 'Content-Type': 'application/json',
        }).copyWith(method: method),
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
