import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../ai_endpoint_policy.dart';
import '../ai_model_provider.dart';
import '../ai_provider_storage.dart';
import 'tool_call_models.dart';

class OpenAIToolCallingModel implements ToolCallingModel {
  OpenAIToolCallingModel._({
    required AIModelProviderConfig config,
    required String apiKey,
    Dio? dio,
  })  : _config = config,
        _apiKey = apiKey,
        _baseEndpoint = AIEndpointPolicy.parseBaseEndpoint(config.endpoint),
        _dio = dio ?? Dio();

  static Future<OpenAIToolCallingModel> create({
    required AIProviderSettingsStore settingsStore,
    Dio? dio,
  }) async {
    final config = await settingsStore.readConfig();
    if (config == null || config.kind != AIModelProviderKind.openAICompatible) {
      throw const AIModelProviderException('个人 Skill 需要 OpenAI 兼容模型');
    }
    final apiKey = await settingsStore.readApiKey();
    if (apiKey == null) {
      throw const AIModelProviderException('未找到 API Key，请重新配置');
    }
    return OpenAIToolCallingModel._(config: config, apiKey: apiKey, dio: dio);
  }

  final AIModelProviderConfig _config;
  final String _apiKey;
  final Uri _baseEndpoint;
  final Dio _dio;
  CancelToken? _cancelToken;

  @override
  AIModelProviderKind get providerKind => AIModelProviderKind.openAICompatible;

  @override
  String get destinationLabel =>
      _config.model.trim().isEmpty ? '用户配置的 OpenAI 兼容模型' : _config.model.trim();

  @override
  String get authorizationScope =>
      '${_config.id}|${_baseEndpoint.toString()}|${_config.model.trim()}';

  @override
  Future<ToolModelTurn> nextTurn({
    required List<ToolConversationMessage> messages,
    required List<ToolDefinition> tools,
  }) async {
    if (kIsWeb) {
      throw const AIModelProviderException('浏览器端不发送第三方模型密钥');
    }
    final token = CancelToken();
    _cancelToken = token;
    try {
      final response = await _dio.postUri<dynamic>(
        AIEndpointPolicy.endpointFor(_baseEndpoint, 'chat/completions'),
        data: <String, dynamic>{
          'model': _config.model,
          'stream': false,
          'messages': messages.map(_message).toList(growable: false),
          'tools': tools
              .map(
                (tool) => <String, dynamic>{
                  'type': 'function',
                  'function': <String, dynamic>{
                    'name': tool.id,
                    'description': tool.description,
                    'parameters': tool.parameters,
                  },
                },
              )
              .toList(growable: false),
          'tool_choice': 'auto',
        },
        cancelToken: token,
        options: AIEndpointPolicy.directRequestOptions(<String, dynamic>{
          'Authorization': 'Bearer $_apiKey',
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        }),
      );
      AIEndpointPolicy.ensureDirectResponse(response);
      final data = response.data;
      if (data is! Map || data['choices'] is! List) {
        throw const AIModelProviderException('Tool Calling 响应格式错误');
      }
      final choices = data['choices'] as List;
      if (choices.isEmpty || choices.first is! Map) {
        throw const AIModelProviderException('模型未返回 Tool Calling 结果');
      }
      final message = (choices.first as Map)['message'];
      if (message is! Map) {
        throw const AIModelProviderException('模型消息格式错误');
      }
      final calls = message['tool_calls'];
      if (calls is List && calls.isNotEmpty) {
        if ((message['content']?.toString().trim() ?? '').isNotEmpty) {
          throw const AIModelProviderException('模型同时返回文本和 Tool Call');
        }
        if (calls.length != 1 || calls.first is! Map) {
          throw const AIModelProviderException('每轮只允许一个 Tool Call');
        }
        final raw = calls.first as Map;
        final function = raw['function'];
        if (function is! Map) {
          throw const AIModelProviderException('Tool Call 函数格式错误');
        }
        final decoded = jsonDecode(function['arguments']?.toString() ?? '{}');
        if (decoded is! Map) {
          throw const AIModelProviderException('Tool Call 参数必须是对象');
        }
        final callId = raw['id']?.toString().trim() ?? '';
        final toolName = function['name']?.toString().trim() ?? '';
        if (callId.isEmpty || toolName.isEmpty) {
          throw const AIModelProviderException('Tool Call 缺少 ID 或名称');
        }
        return ToolModelTurn.call(
          LocalToolCall(
            id: callId,
            tool: toolName,
            arguments: Map<String, dynamic>.from(decoded),
          ),
        );
      }
      final content = message['content']?.toString().trim() ?? '';
      return ToolModelTurn.finalAnswer(content);
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) {
        throw const AIModelProviderException('Tool Calling 已取消');
      }
      final responseText = error.response?.data.toString().toLowerCase() ?? '';
      if (responseText.contains('tool') ||
          responseText.contains('function') ||
          error.response?.statusCode == 404) {
        throw const AIModelProviderException('当前模型服务不支持 Tool Calling');
      }
      throw const AIModelProviderException('无法连接 Tool Calling 模型');
    } on FormatException {
      throw const AIModelProviderException('Tool Call 参数不是有效 JSON');
    } finally {
      if (identical(_cancelToken, token)) _cancelToken = null;
    }
  }

  Map<String, dynamic> _message(ToolConversationMessage message) {
    final role = switch (message.role) {
      ToolMessageRole.system => 'system',
      ToolMessageRole.user => 'user',
      ToolMessageRole.assistant => 'assistant',
      ToolMessageRole.tool => 'tool',
    };
    return <String, dynamic>{
      'role': role,
      if (message.role != ToolMessageRole.assistant || message.toolCall == null)
        'content': message.content,
      if (message.toolCallId != null) 'tool_call_id': message.toolCallId,
      if (message.toolCall case final call?)
        'tool_calls': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': call.id,
            'type': 'function',
            'function': <String, dynamic>{
              'name': call.tool,
              'arguments': jsonEncode(call.arguments),
            },
          },
        ],
    };
  }

  @override
  Future<void> cancel() async {
    _cancelToken?.cancel('local_tool_loop_cancelled');
  }
}
