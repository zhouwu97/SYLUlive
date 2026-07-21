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
        _apiKey = apiKey.trim(),
        _baseEndpoint = AIEndpointPolicy.parseBaseEndpoint(config.endpoint),
        _dio = _withDefaultTimeouts(dio ?? Dio());

  static Future<OpenAIToolCallingModel> create({
    required AIProviderSettingsStore settingsStore,
    Dio? dio,
  }) async {
    final config = await settingsStore.readConfig();
    if (config == null || config.kind != AIModelProviderKind.openAICompatible) {
      throw const AIModelProviderConfigurationException(
        '个人助手尚未配置模型，请先完成模型设置',
      );
    }
    final apiKey = await settingsStore.readApiKey();
    if (apiKey == null) {
      throw const AIModelProviderConfigurationException(
        '未找到 API Key，请重新配置',
      );
    }
    return OpenAIToolCallingModel._(
      config: config,
      apiKey: apiKey,
      dio: dio,
    );
  }

  static OpenAIToolCallingModel fromConfig({
    required AIModelProviderConfig config,
    required String apiKey,
    Dio? dio,
  }) {
    return OpenAIToolCallingModel._(
      config: config,
      apiKey: apiKey,
      dio: dio,
    );
  }

  static Dio _withDefaultTimeouts(Dio dio) {
    dio.options.connectTimeout ??= const Duration(seconds: 10);
    dio.options.sendTimeout ??= const Duration(seconds: 20);
    dio.options.receiveTimeout ??= const Duration(seconds: 90);
    return dio;
  }

  final AIModelProviderConfig _config;
  final String _apiKey;
  final Uri _baseEndpoint;
  final Dio _dio;
  CancelToken? _cancelToken;
  OpenAIWireApi? _detectedWireApi;

  @override
  AIModelProviderKind get providerKind => AIModelProviderKind.openAICompatible;

  @override
  String get destinationLabel {
    final model = _config.model.trim();
    final target = _baseEndpoint.origin;
    return model.isEmpty ? target : '$target · $model';
  }

  /// 用不含个人数据的固定函数验证服务是否真正支持 Tool Calling。
  Future<void> probeToolCalling() async {
    const toolName = 'connection_test';
    final turn = await _nextTurn(
      messages: const <ToolConversationMessage>[
        ToolConversationMessage(
          role: ToolMessageRole.system,
          content: '这是连接测试。必须调用指定工具，不要输出普通文本。',
        ),
        ToolConversationMessage(
          role: ToolMessageRole.user,
          content: '请调用 connection_test，参数 status 必须为 ok。',
        ),
      ],
      tools: <ToolDefinition>[
        ToolDefinition(
          id: toolName,
          description: '验证模型服务支持函数调用，不读取或发送任何个人数据',
          parameters: const <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'status': <String, dynamic>{
                'type': 'string',
                'enum': <String>['ok'],
              },
            },
            'required': <String>['status'],
            'additionalProperties': false,
          },
        ),
      ],
      forcedToolName: toolName,
    );
    if (turn.toolCall?.tool != toolName ||
        turn.toolCall?.arguments['status'] != 'ok') {
      throw const AIModelProviderCompatibilityException(
        '服务可以连接，但没有按要求返回 Tool Calling',
      );
    }
  }

  @override
  Future<ToolModelTurn> nextTurn({
    required List<ToolConversationMessage> messages,
    required List<ToolDefinition> tools,
  }) {
    return _nextTurn(messages: messages, tools: tools);
  }

  Future<ToolModelTurn> _nextTurn({
    required List<ToolConversationMessage> messages,
    required List<ToolDefinition> tools,
    String? forcedToolName,
  }) async {
    if (kIsWeb) {
      throw const AIModelProviderConfigurationException(
        '浏览器端不发送第三方模型密钥',
      );
    }
    if (_apiKey.isEmpty) {
      throw const AIModelProviderConfigurationException(
        '未找到 API Key，请重新配置',
      );
    }
    if (_config.model.trim().isEmpty) {
      throw const AIModelProviderConfigurationException('请先填写模型名称');
    }

    final configured = _config.wireApi;
    final selected = configured == OpenAIWireApi.auto
        ? (_detectedWireApi ?? OpenAIWireApi.responses)
        : configured;
    try {
      final turn = await _requestTurn(
        selected,
        messages: messages,
        tools: tools,
        forcedToolName: forcedToolName,
      );
      if (configured == OpenAIWireApi.auto) _detectedWireApi = selected;
      return turn;
    } on _WireApiRejectedException {
      if (configured != OpenAIWireApi.auto ||
          selected != OpenAIWireApi.responses) {
        throw const AIModelProviderCompatibilityException(
          '模型服务不支持所选请求协议',
        );
      }
      try {
        final turn = await _requestTurn(
          OpenAIWireApi.chatCompletions,
          messages: messages,
          tools: tools,
          forcedToolName: forcedToolName,
        );
        _detectedWireApi = OpenAIWireApi.chatCompletions;
        return turn;
      } on _WireApiRejectedException {
        throw const AIModelProviderCompatibilityException(
          '模型服务同时不支持 Responses API 和 Chat Completions',
        );
      }
    }
  }

  Future<ToolModelTurn> _requestTurn(
    OpenAIWireApi wireApi, {
    required List<ToolConversationMessage> messages,
    required List<ToolDefinition> tools,
    String? forcedToolName,
  }) async {
    final token = CancelToken();
    _cancelToken = token;
    try {
      final isResponses = wireApi == OpenAIWireApi.responses;
      final response = await _dio.postUri<dynamic>(
        AIEndpointPolicy.endpointFor(
          _baseEndpoint,
          isResponses ? 'responses' : 'chat/completions',
        ),
        data: isResponses
            ? _responsesPayload(messages, tools, forcedToolName)
            : _chatPayload(messages, tools, forcedToolName),
        cancelToken: token,
        options: AIEndpointPolicy.directRequestOptions(<String, dynamic>{
          'Authorization': 'Bearer $_apiKey',
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        }),
      );
      AIEndpointPolicy.ensureDirectResponse(response);
      return isResponses
          ? _parseResponsesTurn(response.data, tools)
          : _parseChatTurn(response.data, tools);
    } on AIModelProviderException {
      rethrow;
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) {
        throw const AIModelProviderException('Tool Calling 已取消');
      }
      final status = error.response?.statusCode;
      if (status == 400 ||
          status == 404 ||
          status == 405 ||
          status == 415 ||
          status == 422) {
        throw const _WireApiRejectedException();
      }
      final serverMessage = _serverErrorMessage(error.response?.data);
      if (serverMessage.isNotEmpty) {
        throw AIModelProviderException(serverMessage);
      }
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        throw const AIModelProviderException('模型响应超时，请稍后重试');
      }
      throw const AIModelProviderException(
        '无法连接 Tool Calling 模型，请检查地址和网络',
      );
    } on FormatException {
      throw const AIModelProviderCompatibilityException(
        'Tool Call 参数不是有效 JSON',
      );
    } finally {
      if (identical(_cancelToken, token)) _cancelToken = null;
    }
  }

  Map<String, dynamic> _responsesPayload(
    List<ToolConversationMessage> messages,
    List<ToolDefinition> tools,
    String? forcedToolName,
  ) {
    return <String, dynamic>{
      'model': _config.model.trim(),
      'stream': false,
      'input': messages.map(_responsesMessage).toList(growable: false),
      'tools': tools
          .map(
            (tool) => <String, dynamic>{
              'type': 'function',
              'name': _wireToolName(tool.id),
              'description': tool.description,
              'parameters': tool.parameters,
              'strict': false,
            },
          )
          .toList(growable: false),
      'tool_choice': forcedToolName == null
          ? 'auto'
          : <String, dynamic>{
              'type': 'function',
              'name': _wireToolName(forcedToolName),
            },
    };
  }

  Map<String, dynamic> _chatPayload(
    List<ToolConversationMessage> messages,
    List<ToolDefinition> tools,
    String? forcedToolName,
  ) {
    return <String, dynamic>{
      'model': _config.model.trim(),
      'stream': false,
      'messages': messages.map(_chatMessage).toList(growable: false),
      'tools': tools
          .map(
            (tool) => <String, dynamic>{
              'type': 'function',
              'function': <String, dynamic>{
                'name': _wireToolName(tool.id),
                'description': tool.description,
                'parameters': tool.parameters,
              },
            },
          )
          .toList(growable: false),
      'tool_choice': forcedToolName == null
          ? 'auto'
          : <String, dynamic>{
              'type': 'function',
              'function': <String, dynamic>{
                'name': _wireToolName(forcedToolName),
              },
            },
    };
  }

  Map<String, dynamic> _responsesMessage(ToolConversationMessage message) {
    if (message.role == ToolMessageRole.tool) {
      return <String, dynamic>{
        'type': 'function_call_output',
        'call_id': message.toolCallId,
        'output': message.content,
      };
    }
    if (message.role == ToolMessageRole.assistant && message.toolCall != null) {
      final call = message.toolCall!;
      return <String, dynamic>{
        'type': 'function_call',
        'call_id': call.id,
        'name': _wireToolName(call.tool),
        'arguments': jsonEncode(call.arguments),
      };
    }
    return <String, dynamic>{
      'role': switch (message.role) {
        ToolMessageRole.system => 'system',
        ToolMessageRole.user => 'user',
        ToolMessageRole.assistant => 'assistant',
        ToolMessageRole.tool => 'tool',
      },
      'content': message.content,
    };
  }

  Map<String, dynamic> _chatMessage(ToolConversationMessage message) {
    if (message.role == ToolMessageRole.tool &&
        message.toolCall?.legacyFunctionCall == true) {
      return <String, dynamic>{
        'role': 'function',
        'name': _wireToolName(message.toolCall!.tool),
        'content': message.content,
      };
    }
    final role = switch (message.role) {
      ToolMessageRole.system => 'system',
      ToolMessageRole.user => 'user',
      ToolMessageRole.assistant => 'assistant',
      ToolMessageRole.tool => 'tool',
    };
    final call = message.toolCall;
    if (message.role == ToolMessageRole.assistant &&
        call?.legacyFunctionCall == true) {
      return <String, dynamic>{
        'role': role,
        'content': message.content,
        'function_call': <String, dynamic>{
          'name': _wireToolName(call!.tool),
          'arguments': jsonEncode(call.arguments),
        },
      };
    }
    return <String, dynamic>{
      'role': role,
      if (message.role != ToolMessageRole.assistant || call == null)
        'content': message.content,
      if (message.toolCallId != null) 'tool_call_id': message.toolCallId,
      if (call != null)
        'tool_calls': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': call.id,
            'type': 'function',
            'function': <String, dynamic>{
              'name': _wireToolName(call.tool),
              'arguments': jsonEncode(call.arguments),
            },
          },
        ],
    };
  }

  ToolModelTurn _parseResponsesTurn(
    dynamic value,
    List<ToolDefinition> tools,
  ) {
    final data = _asMap(value, 'Responses API 返回格式错误');
    final output = data['output'];
    if (output is! List) {
      throw const AIModelProviderCompatibilityException(
        'Responses API 未返回 output',
      );
    }
    final calls = output.whereType<Map>().where(
          (item) => item['type']?.toString() == 'function_call',
        );
    if (calls.isNotEmpty) {
      // 本地编排器按轮次执行调用；模型偶尔一次返回多个时先取第一个，
      // 下一轮携带结果后由模型继续提出后续调用，避免整次请求失败。
      final raw = Map<String, dynamic>.from(calls.first);
      return ToolModelTurn.call(
        _localCall(
          id: raw['call_id']?.toString() ?? raw['id']?.toString() ?? '',
          wireName: raw['name']?.toString() ?? '',
          rawArguments: raw['arguments'],
          tools: tools,
        ),
      );
    }
    final text = _responsesText(data, output);
    return ToolModelTurn.finalAnswer(text);
  }

  ToolModelTurn _parseChatTurn(
    dynamic value,
    List<ToolDefinition> tools,
  ) {
    final data = _asMap(value, 'Chat Completions 返回格式错误');
    final choices = data['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      throw const AIModelProviderCompatibilityException(
        '模型未返回 Chat Completions 结果',
      );
    }
    final message = (choices.first as Map)['message'];
    if (message is! Map) {
      throw const AIModelProviderCompatibilityException('模型消息格式错误');
    }
    final calls = message['tool_calls'];
    if (calls is List && calls.isNotEmpty) {
      if (calls.first is! Map) {
        throw const AIModelProviderCompatibilityException('Tool Call 格式错误');
      }
      // 本地编排器按轮次执行调用；模型偶尔一次返回多个时先取第一个，
      // 下一轮携带结果后由模型继续提出后续调用，避免整次请求失败。
      final raw = calls.first as Map;
      final function = raw['function'];
      if (function is! Map) {
        throw const AIModelProviderCompatibilityException(
          'Tool Call 函数格式错误',
        );
      }
      return ToolModelTurn.call(
        _localCall(
          id: raw['id']?.toString() ?? '',
          wireName: function['name']?.toString() ?? '',
          rawArguments: function['arguments'],
          tools: tools,
        ),
      );
    }
    final legacy = message['function_call'];
    if (legacy is Map) {
      final wireName = legacy['name']?.toString() ?? '';
      return ToolModelTurn.call(
        _localCall(
          id: 'legacy-${wireName.hashCode}',
          wireName: wireName,
          rawArguments: legacy['arguments'],
          tools: tools,
          legacy: true,
        ),
      );
    }
    return ToolModelTurn.finalAnswer(_chatContent(message['content']));
  }

  LocalToolCall _localCall({
    required String id,
    required String wireName,
    required dynamic rawArguments,
    required List<ToolDefinition> tools,
    bool legacy = false,
  }) {
    final decoded = rawArguments is Map
        ? rawArguments
        : jsonDecode(rawArguments?.toString() ?? '{}');
    if (decoded is! Map) {
      throw const AIModelProviderCompatibilityException(
        'Tool Call 参数必须是对象',
      );
    }
    final matches = tools.where((tool) => _wireToolName(tool.id) == wireName);
    final toolName = matches.isEmpty ? wireName : matches.first.id;
    return LocalToolCall(
      id: id,
      tool: toolName,
      arguments: Map<String, dynamic>.from(decoded),
      legacyFunctionCall: legacy,
    );
  }

  Map<String, dynamic> _asMap(dynamic value, String message) {
    if (value is Map) return Map<String, dynamic>.from(value);
    throw AIModelProviderCompatibilityException(message);
  }

  String _responsesText(Map<String, dynamic> data, List<dynamic> output) {
    final direct = data['output_text'];
    if (direct is String && direct.trim().isNotEmpty) return direct.trim();
    final parts = <String>[];
    for (final item in output.whereType<Map>()) {
      if (item['type'] != 'message' || item['content'] is! List) continue;
      for (final content in (item['content'] as List).whereType<Map>()) {
        final text = content['text'];
        if (text is String && text.trim().isNotEmpty) parts.add(text.trim());
        if (text is Map) {
          final value = text['value']?.toString().trim() ?? '';
          if (value.isNotEmpty) parts.add(value);
        }
      }
    }
    return parts.join('\n').trim();
  }

  String _chatContent(dynamic value) {
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

  String _wireToolName(String toolId) =>
      toolId.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '__');

  String _serverErrorMessage(dynamic data) {
    if (data is! Map) return '';
    final error = data['error'];
    if (error is Map) return error['message']?.toString().trim() ?? '';
    return data['message']?.toString().trim() ?? '';
  }

  @override
  Future<void> cancel() async {
    _cancelToken?.cancel('local_tool_loop_cancelled');
  }
}

class _WireApiRejectedException implements Exception {
  const _WireApiRejectedException();
}
