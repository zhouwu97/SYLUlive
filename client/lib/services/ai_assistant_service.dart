import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:dio/dio.dart';

import '../models/ai_capabilities.dart';
import '../models/ai_conversation.dart';
import '../models/ai_personal_data_evidence.dart';
import '../models/ai_run.dart';
import '../models/ai_run_event.dart';
import '../models/ai_source.dart';

const int _maxCreateRunAttempts = 2;
const Duration _firstRetryDelay = Duration(milliseconds: 400);
const Duration _secondRetryDelay = Duration(milliseconds: 1200);

class AiRunSources {
  const AiRunSources({
    this.sources = const [],
    this.personalDataEvidence = const [],
  });

  final List<AiSource> sources;
  final List<AiPersonalDataEvidence> personalDataEvidence;
}

/// 判断创建 Run 的失败是否属于可以用同一 request id 重试的链路问题。
/// 400/401/403/422/429 等业务拒绝不重试：重试不会改变结果，只会浪费配额。
bool isTransientCreateRunError(DioException error) {
  final status = error.response?.statusCode;
  if (status != null) {
    return status >= 500 && status < 600;
  }
  switch (error.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.connectionError:
      return true;
    case DioExceptionType.badResponse:
    case DioExceptionType.cancel:
    case DioExceptionType.badCertificate:
      return false;
    default:
      // unknown / transformTimeout 等未定型故障按链路问题处理：
      // 幂等键保证重试不会重复创建 Run。
      return true;
  }
}

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

  /// 创建 Run。服务端按 user_id + client_request_id 做幂等，
  /// 因此网络类失败可以安全地用**同一个** clientRequestId 重试：
  /// 若上一次请求其实已经建好 Run，只是响应丢失，重试会命中 duplicate 而不会创建第二个 Run。
  Future<AiRunCreation> createRun({
    required String conversationId,
    required String clientRequestId,
    required String message,
  }) async {
    for (var attempt = 0; attempt < _maxCreateRunAttempts; attempt++) {
      try {
        return await _createRunOnce(
          conversationId: conversationId,
          clientRequestId: clientRequestId,
          message: message,
        );
      } on DioException catch (error) {
        final lastAttempt = attempt == _maxCreateRunAttempts - 1;
        _logCreateRunFailure(clientRequestId, attempt, error);
        if (lastAttempt || !isTransientCreateRunError(error)) {
          throw _exceptionFromDio(error, fallback: '创建 AI 请求失败');
        }
        await Future<void>.delayed(_createRunBackoff(attempt));
      }
    }
    throw const AiAssistantServiceException('创建 AI 请求失败', retryable: true);
  }

  Future<AiRunCreation> _createRunOnce({
    required String conversationId,
    required String clientRequestId,
    required String message,
  }) async {
    final response = await _dio.post(
      '/ai/runs',
      data: {
        if (conversationId.isNotEmpty) 'conversation_id': conversationId,
        'client_request_id': clientRequestId,
        'message': message,
      },
      // 服务端访问日志记录同一个 ID，便于区分“请求未到达”与“响应丢失”。
      options: Options(headers: {'X-Client-Request-ID': clientRequestId}),
    );
    if (response.statusCode != 200 && response.statusCode != 202) {
      throw _exceptionFromResponse(response, fallback: '创建 AI 请求失败');
    }
    final data = _map(response.data);
    return AiRunCreation(
      run: AiRun.fromJson(_map(data['run'])),
      duplicate: data['duplicate'] == true,
    );
  }

  Duration _createRunBackoff(int attempt) =>
      attempt == 0 ? _firstRetryDelay : _secondRetryDelay;

  /// 只记录可用于定位链路的元数据，不记录问题正文、令牌或个人数据。
  void _logCreateRunFailure(String requestId, int attempt, DioException error) {
    final uri = error.requestOptions.uri;
    developer.log(
      'ai_create_run_failed request_id=$requestId attempt=$attempt '
      'type=${error.type.name} host=${uri.host} status=${error.response?.statusCode ?? '-'}',
      name: 'AiAssistantService',
    );
  }

  Future<AiRun> getRun(String runId) async {
    final response = await _dio.get('/ai/runs/$runId');
    _expectStatus(response, 200);
    return AiRun.fromJson(_map(_map(response.data)['run']));
  }

  /// 恢复已完成 Run 的来源事件快照。
  ///
  /// 该接口是 additive contract；旧服务端暂未提供时由 Provider 继续走
  /// 会话 DTO / chunk 正文 fallback，不会因为来源接口失败而隐藏回答正文。
  Future<AiRunSources> getRunSources(String runId) async {
    final response = await _dio.get('/ai/runs/$runId/sources');
    _expectStatus(response, 200);
    final data = _map(response.data);
    final rawSources = data['sources'];
    final sources = rawSources is! List
        ? const <AiSource>[]
        : rawSources
            .whereType<Map>()
            .map((item) => AiSource.fromJson(Map<String, dynamic>.from(item)))
            .toList(growable: false);
    final rawEvidence = data['personal_data_evidence'];
    final evidence = rawEvidence is! List
        ? const <AiPersonalDataEvidence>[]
        : rawEvidence
            .whereType<Map>()
            .map((item) => AiPersonalDataEvidence.fromJson(
                Map<String, dynamic>.from(item)))
            .toList(growable: false);
    return AiRunSources(sources: sources, personalDataEvidence: evidence);
  }

  Future<AiRun> cancelRun(String runId) async {
    late Response<dynamic> response;
    try {
      response = await _dio.post('/ai/runs/$runId/cancel');
    } on DioException catch (error) {
      throw _exceptionFromDio(error, fallback: '取消回答失败');
    }
    _expectStatus(response, 200);
    return AiRun.fromJson(_map(_map(response.data)['run']));
  }

  /// 提交当前 Run 的一次性权限决定，不修改长期授权策略。
  Future<void> submitRunConsent({
    required String runId,
    required String scope,
    required bool granted,
  }) async {
    late Response<dynamic> response;
    try {
      response = await _dio.post(
        '/ai/runs/$runId/consent',
        data: <String, dynamic>{'scope': scope, 'granted': granted},
      );
    } on DioException catch (error) {
      throw _exceptionFromDio(error, fallback: '提交本次授权失败');
    }
    _expectStatus(response, 202);
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

  /// 没有响应的 DioException 必须按网络故障归类。
  /// 否则连接超时会退化成不可重试的“创建 AI 请求失败”，用户既看不到原因也无法重试。
  AiAssistantServiceException _exceptionFromDio(
    DioException error, {
    required String fallback,
  }) {
    if (error.response != null) {
      return _exceptionFromResponse(error.response, fallback: fallback);
    }
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
        return const AiAssistantServiceException(
          '连接服务器超时，请检查网络后重试',
          code: 'network_connection_timeout',
          retryable: true,
        );
      case DioExceptionType.sendTimeout:
        return const AiAssistantServiceException(
          '请求发送超时，请稍后重试',
          code: 'network_send_timeout',
          retryable: true,
        );
      case DioExceptionType.receiveTimeout:
        return const AiAssistantServiceException(
          '服务器响应超时，正在确认请求状态',
          code: 'network_receive_timeout',
          retryable: true,
        );
      case DioExceptionType.connectionError:
        return const AiAssistantServiceException(
          '网络连接暂时不可用',
          code: 'network_connection_error',
          retryable: true,
        );
      case DioExceptionType.cancel:
        return const AiAssistantServiceException(
          '请求已取消',
          code: 'request_cancelled',
        );
      case DioExceptionType.badCertificate:
        return const AiAssistantServiceException(
          '服务器证书校验失败',
          code: 'bad_certificate',
        );
      default:
        return AiAssistantServiceException(fallback, retryable: true);
    }
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
