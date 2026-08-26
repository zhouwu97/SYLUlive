import 'dart:async';

import 'package:dio/dio.dart';

import 'diagnostic_log_service.dart';

typedef AiPermissionDiagnosticWriter = Future<void> Function({
  required String route,
  required int durationMs,
  required int? httpStatus,
  required String errorCode,
  required String requestId,
});

/// 校园 Agent 访问个人数据的长期授权范围。
enum AiPersonalDataPermissionScope {
  personalDataAccess,
  deviceCacheAccess,
  remoteEduRefresh,
  erkeSnapshotUpload,
  academicCloudStorage,
  externalModelAnalysis;

  String get wireValue => switch (this) {
        AiPersonalDataPermissionScope.personalDataAccess =>
          'ai_personal_data_access',
        AiPersonalDataPermissionScope.deviceCacheAccess =>
          'ai_device_cache_access',
        AiPersonalDataPermissionScope.remoteEduRefresh =>
          'ai_remote_edu_refresh',
        AiPersonalDataPermissionScope.erkeSnapshotUpload =>
          'erke_snapshot_upload',
        AiPersonalDataPermissionScope.academicCloudStorage =>
          'academic_cloud_storage',
        AiPersonalDataPermissionScope.externalModelAnalysis =>
          'ai_external_model_analysis',
      };

  static AiPersonalDataPermissionScope? fromWireValue(String value) {
    for (final scope in AiPersonalDataPermissionScope.values) {
      if (scope.wireValue == value) return scope;
    }
    return null;
  }
}

/// 服务端可跨会话保存的个人数据授权策略。
enum AiPersonalDataPermissionPolicy {
  ask,
  always,
  never;

  String get wireValue => name;

  static AiPersonalDataPermissionPolicy? fromWireValue(String value) {
    for (final policy in AiPersonalDataPermissionPolicy.values) {
      if (policy.wireValue == value) return policy;
    }
    return null;
  }
}

enum AiAgentPermissionMode {
  ask,
  trusted;

  String get wireValue => name;

  static AiAgentPermissionMode fromWireValue(String value) {
    return value == 'trusted'
        ? AiAgentPermissionMode.trusted
        : AiAgentPermissionMode.ask;
  }
}

class AiPersonalDataPermission {
  const AiPersonalDataPermission({
    required this.scope,
    required this.policy,
  });

  final AiPersonalDataPermissionScope scope;
  final AiPersonalDataPermissionPolicy policy;

  factory AiPersonalDataPermission.fromJson(Map<String, dynamic> json) {
    final scope = AiPersonalDataPermissionScope.fromWireValue(
      json['scope']?.toString() ?? '',
    );
    final policy = AiPersonalDataPermissionPolicy.fromWireValue(
      json['policy']?.toString() ?? '',
    );
    if (scope == null || policy == null) {
      throw const AiPersonalDataPermissionException('个人数据权限响应无效');
    }
    return AiPersonalDataPermission(scope: scope, policy: policy);
  }
}

/// 读取和更新校园 Agent 的长期个人数据授权；Dio 复用当前用户的 JWT。
class AiPersonalDataPermissionService {
  AiPersonalDataPermissionService(
    this._dio, {
    AiPermissionDiagnosticWriter? diagnosticWriter,
  }) : _diagnosticWriter = diagnosticWriter ?? _writePermissionDiagnostic;

  final Dio _dio;
  final AiPermissionDiagnosticWriter _diagnosticWriter;

  Future<AiAgentPermissionMode> getMode() async {
    try {
      final response = await _dio.get('/ai/permissions/mode');
      if (response.statusCode != 200 || response.data is! Map) {
        throw const AiPersonalDataPermissionException('读取 Agent 权限模式失败');
      }
      return AiAgentPermissionMode.fromWireValue(
        (response.data as Map)['mode']?.toString() ?? 'ask',
      );
    } on AiPersonalDataPermissionException {
      rethrow;
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) {
        throw const AiPersonalDataPermissionException('请先登录后再设置 Agent 权限');
      }
      throw const AiPersonalDataPermissionException('读取 Agent 权限模式失败，请稍后重试');
    }
  }

  Future<AiAgentPermissionMode> setMode(AiAgentPermissionMode mode) async {
    final stopwatch = Stopwatch()..start();
    try {
      final response = await _dio.put(
        '/ai/permissions/mode',
        data: <String, String>{'mode': mode.wireValue},
      );
      if (response.statusCode != 200 || response.data is! Map) {
        final apiError = _AiPermissionApiError.fromResponse(response);
        throw AiPersonalDataPermissionException(
          _setModeMessage(apiError),
          code: apiError.code,
          httpStatus: apiError.httpStatus,
          requestId: apiError.requestId,
        );
      }
      return AiAgentPermissionMode.fromWireValue(
        (response.data as Map)['mode']?.toString() ?? mode.wireValue,
      );
    } on AiPersonalDataPermissionException {
      rethrow;
    } on DioException catch (error) {
      stopwatch.stop();
      final apiError = _AiPermissionApiError.fromDio(error);
      _recordSetModeFailure(
        apiError,
        stopwatch.elapsedMilliseconds,
        _diagnosticWriter,
      );
      throw AiPersonalDataPermissionException(
        _setModeMessage(apiError),
        code: apiError.code,
        httpStatus: apiError.httpStatus,
        requestId: apiError.requestId,
      );
    }
  }

  Future<List<AiPersonalDataPermission>> list() async {
    try {
      final response = await _dio.get('/ai/personal-data-access');
      if (response.statusCode != 200 || response.data is! Map) {
        throw const AiPersonalDataPermissionException('读取个人数据权限失败');
      }
      final values = (response.data as Map)['permissions'];
      if (values is! List) {
        throw const AiPersonalDataPermissionException('个人数据权限响应无效');
      }
      return values
          .whereType<Map>()
          .map((value) => AiPersonalDataPermission.fromJson(
                Map<String, dynamic>.from(value),
              ))
          .toList(growable: false);
    } on AiPersonalDataPermissionException {
      rethrow;
    } on DioException {
      throw const AiPersonalDataPermissionException('读取个人数据权限失败，请稍后重试');
    }
  }

  Future<AiPersonalDataPermission> update({
    required AiPersonalDataPermissionScope scope,
    required AiPersonalDataPermissionPolicy policy,
  }) async {
    try {
      final response = await _dio.put(
        '/ai/personal-data-access',
        data: <String, String>{
          'scope': scope.wireValue,
          'policy': policy.wireValue,
        },
      );
      if (response.statusCode != 200 || response.data is! Map) {
        throw const AiPersonalDataPermissionException('更新个人数据权限失败');
      }
      final permission = (response.data as Map)['permission'];
      if (permission is! Map) {
        throw const AiPersonalDataPermissionException('个人数据权限响应无效');
      }
      return AiPersonalDataPermission.fromJson(
        Map<String, dynamic>.from(permission),
      );
    } on AiPersonalDataPermissionException {
      rethrow;
    } on DioException {
      throw const AiPersonalDataPermissionException('更新个人数据权限失败，请稍后重试');
    }
  }
}

class AiPersonalDataPermissionException implements Exception {
  const AiPersonalDataPermissionException(
    this.message, {
    this.code,
    this.httpStatus,
    this.requestId,
  });

  final String message;
  final String? code;
  final int? httpStatus;
  final String? requestId;

  @override
  String toString() => message;
}

class _AiPermissionApiError {
  const _AiPermissionApiError({
    this.httpStatus,
    this.code = '',
    this.message = '',
    this.requestId = '',
    this.isNetworkError = false,
  });

  final int? httpStatus;
  final String code;
  final String message;
  final String requestId;
  final bool isNetworkError;

  factory _AiPermissionApiError.fromDio(DioException error) {
    final response = error.response;
    final data = response?.data;
    final map = data is Map ? data : null;
    return _AiPermissionApiError(
      httpStatus: response?.statusCode,
      code: _boundedText(map?['code']),
      message: _boundedText(map?['message']),
      requestId: _requestId(
        map?['request_id'],
        response?.headers.value('x-request-id'),
        error.requestOptions.headers['X-Request-ID'],
      ),
      isNetworkError: response == null,
    );
  }

  factory _AiPermissionApiError.fromResponse(Response<dynamic> response) {
    final data = response.data;
    final map = data is Map ? data : null;
    return _AiPermissionApiError(
      httpStatus: response.statusCode,
      code: _boundedText(map?['code']),
      message: _boundedText(map?['message']),
      requestId: _requestId(
        map?['request_id'],
        response.headers.value('x-request-id'),
      ),
    );
  }
}

String _setModeMessage(_AiPermissionApiError error) {
  switch (error.httpStatus) {
    case 400:
      return error.message.isNotEmpty ? error.message : 'Agent 权限模式参数无效';
    case 401:
      return '请先登录后再设置 Agent 权限';
    case 403:
      return '当前账号没有修改 Agent 权限的权限';
    case 404:
      return 'Agent 权限模式接口不存在，请更新应用';
    case 409:
      return error.message.isNotEmpty ? error.message : 'Agent 权限模式正在变更，请稍后重试';
    default:
      if (error.httpStatus != null && error.httpStatus! >= 500) {
        return error.message.isNotEmpty ? error.message : '个人数据权限服务暂时不可用，请稍后重试';
      }
      if (error.isNetworkError) return '网络连接失败，请检查网络后重试';
      return error.message.isNotEmpty ? error.message : '更新 Agent 权限模式失败，请稍后重试';
  }
}

void _recordSetModeFailure(
  _AiPermissionApiError error,
  int durationMs,
  AiPermissionDiagnosticWriter writer,
) {
  final code = error.code.isNotEmpty
      ? error.code
      : error.isNetworkError
          ? 'network_error'
          : 'http_error';
  final requestId = error.requestId;

  try {
    unawaited(
      writer(
        route: '/ai/permissions/mode',
        durationMs: durationMs,
        httpStatus: error.httpStatus,
        errorCode: code,
        requestId: requestId,
      ).catchError((_) {}),
    );
  } catch (_) {
    // 诊断日志不能反向影响权限设置错误的呈现。
  }
}

Future<void> _writePermissionDiagnostic({
  required String route,
  required int durationMs,
  required int? httpStatus,
  required String errorCode,
  required String requestId,
}) async {
  await DiagnosticLogService.instance.recordError(
    source: 'AI 权限',
    type: 'Agent 权限模式更新失败',
    summary: 'PUT $route 请求失败',
    detail: [
      'HTTP: ${httpStatus ?? "无响应"}',
      '耗时: ${durationMs}ms',
      '错误码: $errorCode',
      if (requestId.isNotEmpty) '请求 ID: $requestId',
    ].join('\n'),
    eventCode: 'ai_permission_mode_update_failed',
    category: 'ai_permission',
    operation: 'put',
    durationMs: durationMs,
    httpStatus: httpStatus,
    route: route,
    traceId: requestId,
    metadata: <String, Object?>{
      'method': 'PUT',
      'errorCode': errorCode,
      if (requestId.isNotEmpty) 'requestId': requestId,
    },
  );
}

String _boundedText(Object? value) {
  final text = value?.toString().trim() ?? '';
  if (text.length <= 200) return text;
  return text.substring(0, 200);
}

String _requestId(
  Object? bodyValue,
  String? headerValue, [
  Object? requestValue,
]) {
  for (final value in <Object?>[bodyValue, headerValue, requestValue]) {
    final text = _boundedText(value);
    if (text.isNotEmpty) return text;
  }
  return '';
}
