import 'package:dio/dio.dart';

import '../../services/diagnostic_log_service.dart';
import 'device_job_models.dart';

typedef DeviceJobDiagnosticWriter = Future<void> Function(
  DeviceJobApiException error,
);

abstract interface class DeviceJobApi {
  Future<void> register({
    required String installationId,
    required List<String> toolNames,
    required int bridgeProtocolVersion,
    required String clientVersion,
    String pushToken,
  });

  Future<List<DeviceToolJob>> pending(String installationId);

  Future<DeviceToolJob> get(String installationId, String jobId);

  Future<DeviceToolJob> claim(
    String installationId,
    String jobId,
    int stateVersion,
  );

  Future<DeviceToolJob> waitForUser(
    String installationId,
    String jobId,
    int stateVersion,
  );

  Future<DeviceToolJob> progress(
    String installationId,
    String jobId,
    int stateVersion,
    String stage,
  );

  Future<DeviceToolJob> complete(
    String installationId,
    String jobId,
    int stateVersion,
    Map<String, dynamic> result,
  );

  Future<DeviceToolJob> fail(
    String installationId,
    String jobId,
    int stateVersion,
    String errorCode,
  );
}

/// Device Job API 只传 installation_id 和最小化结果，不持久化或记录个人快照。
class DioDeviceJobClient implements DeviceJobApi {
  DioDeviceJobClient(
    this._dio, {
    DeviceJobDiagnosticWriter? diagnosticWriter,
  }) : _diagnosticWriter = diagnosticWriter ?? _writeDiagnosticError;

  final Dio _dio;
  final DeviceJobDiagnosticWriter _diagnosticWriter;

  @override
  Future<void> register({
    required String installationId,
    required List<String> toolNames,
    required int bridgeProtocolVersion,
    required String clientVersion,
    String pushToken = '',
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      await _dio.put(
        '/device/registration',
        data: <String, dynamic>{
          'installation_id': _requiredInstallationId(installationId),
          'push_token': pushToken.trim(),
          'tool_names': toolNames,
          'bridge_protocol_version': bridgeProtocolVersion,
          'client_version': clientVersion.trim(),
        },
      );
    } on DioException catch (error) {
      throw await _handleDioError(
        error,
        operation: 'register',
        route: '/device/registration',
        method: 'PUT',
        durationMs: stopwatch.elapsedMilliseconds,
      );
    }
  }

  @override
  Future<List<DeviceToolJob>> pending(String installationId) async {
    final stopwatch = Stopwatch()..start();
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/device/jobs/pending',
        options: _options(installationId),
      );
      final jobs = _responseMap(response.data)['jobs'];
      if (jobs is! List) throw const FormatException('设备任务列表格式无效');
      return List<DeviceToolJob>.unmodifiable(
        jobs.map((item) {
          if (item is! Map) throw const FormatException('设备任务格式无效');
          return DeviceToolJob.fromJson(Map<String, dynamic>.from(item));
        }),
      );
    } on DioException catch (error) {
      throw await _handleDioError(
        error,
        operation: 'pending',
        route: '/device/jobs/pending',
        method: 'GET',
        durationMs: stopwatch.elapsedMilliseconds,
      );
    }
  }

  @override
  Future<DeviceToolJob> get(String installationId, String jobId) {
    final route = '/device/jobs/${_requiredJobId(jobId)}';
    return _jobRequest(
      () => _dio.get<Map<String, dynamic>>(
        route,
        options: _options(installationId),
      ),
      operation: 'get',
      route: '/device/jobs/:jobId',
      method: 'GET',
    );
  }

  @override
  Future<DeviceToolJob> claim(
    String installationId,
    String jobId,
    int stateVersion,
  ) {
    final route = '/device/jobs/${_requiredJobId(jobId)}/claim';
    return _jobRequest(
      () => _dio.post<Map<String, dynamic>>(
        route,
        data: <String, dynamic>{'state_version': stateVersion},
        options: _options(installationId),
      ),
      operation: 'claim',
      route: '/device/jobs/:jobId/claim',
      method: 'POST',
    );
  }

  @override
  Future<DeviceToolJob> waitForUser(
    String installationId,
    String jobId,
    int stateVersion,
  ) {
    final route = '/device/jobs/${_requiredJobId(jobId)}/waiting_user';
    return _jobRequest(
      () => _dio.post<Map<String, dynamic>>(
        route,
        data: <String, dynamic>{'state_version': stateVersion},
        options: _options(installationId),
      ),
      operation: 'waiting_user',
      route: '/device/jobs/:jobId/waiting_user',
      method: 'POST',
    );
  }

  @override
  Future<DeviceToolJob> progress(
    String installationId,
    String jobId,
    int stateVersion,
    String stage,
  ) {
    final route = '/device/jobs/${_requiredJobId(jobId)}/progress';
    return _jobRequest(
      () => _dio.post<Map<String, dynamic>>(
        route,
        data: <String, dynamic>{
          'state_version': stateVersion,
          'stage': stage,
        },
        options: _options(installationId),
      ),
      operation: 'progress',
      route: '/device/jobs/:jobId/progress',
      method: 'POST',
    );
  }

  @override
  Future<DeviceToolJob> complete(
    String installationId,
    String jobId,
    int stateVersion,
    Map<String, dynamic> result,
  ) {
    final route = '/device/jobs/${_requiredJobId(jobId)}/complete';
    return _jobRequest(
      () => _dio.post<Map<String, dynamic>>(
        route,
        data: <String, dynamic>{
          'state_version': stateVersion,
          'result': result,
        },
        options: _options(installationId),
      ),
      operation: 'complete',
      route: '/device/jobs/:jobId/complete',
      method: 'POST',
    );
  }

  @override
  Future<DeviceToolJob> fail(
    String installationId,
    String jobId,
    int stateVersion,
    String errorCode,
  ) {
    final route = '/device/jobs/${_requiredJobId(jobId)}/fail';
    return _jobRequest(
      () => _dio.post<Map<String, dynamic>>(
        route,
        data: <String, dynamic>{
          'state_version': stateVersion,
          'error_code': errorCode,
        },
        options: _options(installationId),
      ),
      operation: 'fail',
      route: '/device/jobs/:jobId/fail',
      method: 'POST',
    );
  }

  Future<DeviceToolJob> _jobRequest(
    Future<Response<Map<String, dynamic>>> Function() request, {
    required String operation,
    required String route,
    required String method,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final response = await request();
      final job = _responseMap(response.data)['job'];
      if (job is! Map) throw const FormatException('设备任务响应格式无效');
      return DeviceToolJob.fromJson(Map<String, dynamic>.from(job));
    } on DioException catch (error) {
      throw await _handleDioError(
        error,
        operation: operation,
        route: route,
        method: method,
        durationMs: stopwatch.elapsedMilliseconds,
      );
    }
  }

  Options _options(String installationId) => Options(
        headers: <String, String>{
          'X-Device-Installation-ID': _requiredInstallationId(installationId),
        },
      );

  static Map<String, dynamic> _responseMap(Map<String, dynamic>? value) {
    if (value == null) throw const FormatException('设备任务响应为空');
    return value;
  }

  static String _requiredInstallationId(String value) {
    final result = value.trim();
    if (result.isEmpty || result.length > 128) {
      throw const FormatException('设备安装标识无效');
    }
    return result;
  }

  static String _requiredJobId(String value) {
    final result = value.trim();
    if (result.isEmpty || result.length > 36) {
      throw const FormatException('设备任务标识无效');
    }
    return result;
  }

  Future<DeviceJobApiException> _handleDioError(
    DioException error, {
    required String operation,
    required String route,
    required String method,
    required int durationMs,
  }) async {
    final data = error.response?.data;
    final code = data is Map && data['code'] is String
        ? data['code'] as String
        : 'device_job_request_failed';
    final statusCode = error.response?.statusCode;
    final exception = DeviceJobApiException(
      code,
      statusCode: statusCode,
      operation: operation,
      dioType: error.type.name,
      retryable: _isRetryable(error.type, statusCode),
      route: route,
      method: method,
      durationMs: durationMs,
    );
    await _diagnosticWriter(exception);
    return exception;
  }
}

bool _isRetryable(DioExceptionType type, int? statusCode) {
  if (statusCode == 429 || (statusCode != null && statusCode >= 500)) {
    return true;
  }
  return switch (type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.connectionError ||
    DioExceptionType.unknown =>
      true,
    _ => false,
  };
}

Future<void> _writeDiagnosticError(DeviceJobApiException error) {
  return DiagnosticLogService.instance.recordError(
    source: '设备工具',
    type: '设备任务请求失败',
    summary: '${_operationLabel(error.operation)}时服务器请求失败',
    detail: [
      '阶段: ${error.operation}',
      'HTTP: ${error.statusCode ?? "无响应"}',
      '网络类型: ${error.dioType}',
      '是否可重试: ${error.retryable ? "是" : "否"}',
    ].join('\n'),
    eventCode: 'device_job_request_failed',
    category: 'device',
    operation: error.operation,
    result: 'failure',
    durationMs: error.durationMs,
    httpStatus: error.statusCode,
    route: error.route,
    metadata: <String, Object?>{
      'method': error.method,
      'dioType': error.dioType,
      'retryable': error.retryable,
      'errorCode': error.code,
    },
  );
}

String _operationLabel(String operation) => switch (operation) {
      'register' => '注册设备',
      'pending' => '拉取待处理任务',
      'get' => '读取任务',
      'claim' => '领取任务',
      'waiting_user' => '等待用户输入',
      'complete' => '提交任务结果',
      'fail' => '上报任务失败',
      _ => '执行设备任务请求',
    };
