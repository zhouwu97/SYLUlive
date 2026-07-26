import 'package:dio/dio.dart';

import 'device_job_models.dart';

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
  DioDeviceJobClient(this._dio);

  final Dio _dio;

  @override
  Future<void> register({
    required String installationId,
    required List<String> toolNames,
    required int bridgeProtocolVersion,
    required String clientVersion,
    String pushToken = '',
  }) async {
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
      throw _apiError(error);
    }
  }

  @override
  Future<List<DeviceToolJob>> pending(String installationId) async {
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
      throw _apiError(error);
    }
  }

  @override
  Future<DeviceToolJob> get(String installationId, String jobId) {
    return _jobRequest(
      () => _dio.get<Map<String, dynamic>>(
        '/device/jobs/${_requiredJobId(jobId)}',
        options: _options(installationId),
      ),
    );
  }

  @override
  Future<DeviceToolJob> claim(
    String installationId,
    String jobId,
    int stateVersion,
  ) {
    return _jobRequest(
      () => _dio.post<Map<String, dynamic>>(
        '/device/jobs/${_requiredJobId(jobId)}/claim',
        data: <String, dynamic>{'state_version': stateVersion},
        options: _options(installationId),
      ),
    );
  }

  @override
  Future<DeviceToolJob> complete(
    String installationId,
    String jobId,
    int stateVersion,
    Map<String, dynamic> result,
  ) {
    return _jobRequest(
      () => _dio.post<Map<String, dynamic>>(
        '/device/jobs/${_requiredJobId(jobId)}/complete',
        data: <String, dynamic>{
          'state_version': stateVersion,
          'result': result,
        },
        options: _options(installationId),
      ),
    );
  }

  @override
  Future<DeviceToolJob> fail(
    String installationId,
    String jobId,
    int stateVersion,
    String errorCode,
  ) {
    return _jobRequest(
      () => _dio.post<Map<String, dynamic>>(
        '/device/jobs/${_requiredJobId(jobId)}/fail',
        data: <String, dynamic>{
          'state_version': stateVersion,
          'error_code': errorCode,
        },
        options: _options(installationId),
      ),
    );
  }

  Future<DeviceToolJob> _jobRequest(
    Future<Response<Map<String, dynamic>>> Function() request,
  ) async {
    try {
      final response = await request();
      final job = _responseMap(response.data)['job'];
      if (job is! Map) throw const FormatException('设备任务响应格式无效');
      return DeviceToolJob.fromJson(Map<String, dynamic>.from(job));
    } on DioException catch (error) {
      throw _apiError(error);
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

  static DeviceJobApiException _apiError(DioException error) {
    final data = error.response?.data;
    final code = data is Map && data['code'] is String
        ? data['code'] as String
        : 'device_job_request_failed';
    return DeviceJobApiException(code, statusCode: error.response?.statusCode);
  }
}
