import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/ai_capabilities.dart';
import '../models/ai_conversation.dart';
import '../models/ai_run.dart';
import '../models/ai_run_event.dart';
import '../models/ai_source.dart';

class AiAssistantService {
  final Dio _dio;
  final Map<int, AiSourceContent> _sourceCache = <int, AiSourceContent>{};
  final Map<int, Future<AiSourceContent>> _sourceRequests =
      <int, Future<AiSourceContent>>{};

  AiAssistantService(this._dio);

  /// 读取来源正文。缓存命中和并发请求合并都在服务层完成，展开卡片不会重复请求。
  Future<AiSourceContent> getSourceContent(int chunkId) {
    if (chunkId <= 0) {
      throw const AiAssistantServiceException('来源正文不可用');
    }
    final cached = _sourceCache[chunkId];
    if (cached != null) return Future.value(cached);
    final pending = _sourceRequests[chunkId];
    if (pending != null) return pending;
    final request = _fetchSourceContent(chunkId);
    _sourceRequests[chunkId] = request;
    return request.whenComplete(() => _sourceRequests.remove(chunkId));
  }

  Future<AiSourceContent> _fetchSourceContent(int chunkId) async {
    final response = await _dio.get('/ai/sources/chunks/$chunkId');
    _expectStatus(response, 200);
    final value = AiSourceContent.fromJson(_map(response.data));
    _sourceCache[chunkId] = value;
    return value;
  }

  Future<AiCapabilities> getCapabilities() async {
    final response = await _dio.get('/ai/capabilities');
    _expectStatus(response, 200);
    final data = _map(response.data);
    return AiCapabilities.fromJson(data);
  }

  Future<AiConversation> createConversation({String title = ''}) async {
    final response =
        await _dio.post('/ai/conversations', data: {'title': title});
    _expectStatus(response, 201);
    return AiConversation.fromJson(_map(_map(response.data)['conversation']));
  }

  Future<List<AiConversation>> listConversations() async {
    final response = await _dio.get('/ai/conversations');
    _expectStatus(response, 200);
    final items = _map(response.data)['conversations'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map((item) => AiConversation.fromJson(Map<String, dynamic>.from(item)))
        .where((item) => item.id.isNotEmpty)
        .toList();
  }

  Future<AiConversationDetails> getConversation(String conversationId) async {
    final response = await _dio.get('/ai/conversations/$conversationId');
    _expectStatus(response, 200);
    return AiConversationDetails.fromJson(_map(response.data));
  }

  Future<void> deleteConversation(String conversationId) async {
    final response = await _dio.delete('/ai/conversations/$conversationId');
    _expectStatus(response, 204);
  }

  Future<AiRunCreation> createRun({
    required String conversationId,
    required String clientRequestId,
    required String message,
  }) async {
    late Response<dynamic> response;
    try {
      response = await _dio.post('/ai/runs', data: {
        if (conversationId.isNotEmpty) 'conversation_id': conversationId,
        'client_request_id': clientRequestId,
        'message': message,
      });
    } on DioException catch (error) {
      throw _exceptionFromResponse(
        error.response,
        fallback: '创建 AI 请求失败',
      );
    }
    if (response.statusCode != 200 && response.statusCode != 202) {
      throw _exceptionFromResponse(response, fallback: '创建 AI 请求失败');
    }
    final data = _map(response.data);
    return AiRunCreation(
      run: AiRun.fromJson(_map(data['run'])),
      duplicate: data['duplicate'] == true,
    );
  }

  Future<AiRun> getRun(String runId) async {
    final response = await _dio.get('/ai/runs/$runId');
    _expectStatus(response, 200);
    return AiRun.fromJson(_map(_map(response.data)['run']));
  }

  Future<AiRun> cancelRun(String runId) async {
    late Response<dynamic> response;
    try {
      response = await _dio.post('/ai/runs/$runId/cancel');
    } on DioException catch (error) {
      throw _exceptionFromResponse(error.response, fallback: '取消回答失败');
    }
    _expectStatus(response, 200);
    return AiRun.fromJson(_map(_map(response.data)['run']));
  }

  /// 读取 SSE，并将 Last-Event-ID 交给服务端完成历史事件回放。
  Stream<AiRunEvent> streamRunEvents(String runId,
      {int lastEventId = 0}) async* {
    final response = await _dio.get<ResponseBody>(
      '/ai/runs/$runId/events',
      options: Options(
        responseType: ResponseType.stream,
        headers: {if (lastEventId > 0) 'Last-Event-ID': '$lastEventId'},
      ),
    );
    if (response.statusCode != 200 || response.data == null) {
      throw _exceptionFromResponse(response, fallback: '连接 AI 事件流失败');
    }
    var eventName = '';
    var eventId = '';
    final dataLines = <String>[];
    final lines = utf8.decoder
        .bind(response.data!.stream)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (line.isEmpty) {
        if (dataLines.isNotEmpty) {
          final data = dataLines.join('\n');
          try {
            final parsed = AiRunEvent.parseSse(data,
                eventName: eventName.isEmpty ? null : eventName);
            yield parsed.seq > 0 || eventId.isEmpty
                ? parsed
                : AiRunEvent.fromJson(
                    {
                      ...jsonDecode(data) as Map<String, dynamic>,
                      'seq': int.tryParse(eventId) ?? 0
                    },
                    eventName: eventName.isEmpty ? null : eventName,
                  );
          } on FormatException {
            // 心跳或代理插入的非 JSON 数据不应中断后续回放。
          }
        }
        eventName = '';
        eventId = '';
        dataLines.clear();
        continue;
      }
      if (line.startsWith(':')) continue;
      final separator = line.indexOf(':');
      final field = separator < 0 ? line : line.substring(0, separator);
      var value = separator < 0 ? '' : line.substring(separator + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      switch (field) {
        case 'event':
          eventName = value;
          break;
        case 'id':
          eventId = value;
          break;
        case 'data':
          dataLines.add(value);
          break;
      }
    }
  }

  void _expectStatus(Response<dynamic> response, int expected) {
    if (response.statusCode != expected) {
      throw _exceptionFromResponse(response, fallback: 'AI 服务请求失败');
    }
  }

  Map<String, dynamic> _map(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    throw const AiAssistantServiceException('AI 服务返回格式错误');
  }

  AiAssistantServiceException _exceptionFromResponse(
    Response<dynamic>? response, {
    required String fallback,
  }) {
    if (response == null) {
      return AiAssistantServiceException(fallback);
    }
    final data = response.data;
    if (data is ResponseBody) {
      return const AiAssistantServiceException('AI 事件流不可用');
    }
    if (data is Map) {
      final map = Map<String, dynamic>.from(data);
      return AiAssistantServiceException(
        map['message']?.toString() ?? fallback,
        code: map['code']?.toString(),
        retryable: map['retryable'] == true,
        statusCode: response.statusCode,
      );
    }
    return AiAssistantServiceException(fallback,
        statusCode: response.statusCode);
  }
}

class AiAssistantServiceException implements Exception {
  final String message;
  final String? code;
  final bool retryable;
  final int? statusCode;

  const AiAssistantServiceException(
    this.message, {
    this.code,
    this.retryable = false,
    this.statusCode,
  });

  @override
  String toString() => message;
}
