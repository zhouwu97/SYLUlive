import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:shenliyuan/services/ai_personal_data_permission_service.dart';

void main() {
  test('个人数据权限解析仅接受已知范围和策略', () {
    final permission = AiPersonalDataPermission.fromJson({
      'scope': 'ai_device_cache_access',
      'policy': 'never',
    });

    expect(permission.scope, AiPersonalDataPermissionScope.deviceCacheAccess);
    expect(permission.policy, AiPersonalDataPermissionPolicy.never);
    expect(
      () => AiPersonalDataPermission.fromJson({
        'scope': 'unknown',
        'policy': 'always',
      }),
      throwsA(isA<AiPersonalDataPermissionException>()),
    );
  });

  test('个人数据权限范围与服务端枚举完全一致', () {
    expect(
      AiPersonalDataPermissionScope.values
          .map((scope) => scope.wireValue)
          .toSet(),
      {
        'ai_personal_data_access',
        'ai_device_cache_access',
        'ai_remote_edu_refresh',
        'erke_snapshot_upload',
        'academic_cloud_storage',
        'ai_external_model_analysis',
      },
    );
  });

  test('setMode 按 HTTP 状态码解析后端错误并记录脱敏诊断', () async {
    final cases = <int, String>{
      400: 'Agent 权限模式参数无效',
      401: '请先登录后再设置 Agent 权限',
      403: '当前账号没有修改 Agent 权限的权限',
      404: 'Agent 权限模式接口不存在，请更新应用',
      409: '权限模式冲突',
      500: '个人数据权限服务暂时不可用',
    };

    for (final entry in cases.entries) {
      final diagnostics = <Map<String, Object?>>[];
      final exception = await _setModeFailure(
        statusCode: entry.key,
        message: entry.key == 409 || entry.key == 500 ? entry.value : null,
        diagnostics: diagnostics,
      );

      expect(exception.message, entry.value);
      expect(exception.httpStatus, entry.key);
      expect(exception.code, 'server_error_${entry.key}');
      expect(diagnostics, hasLength(1));
      expect(diagnostics.single['route'], '/ai/permissions/mode');
      expect(diagnostics.single['httpStatus'], entry.key);
      expect(diagnostics.single['errorCode'], 'server_error_${entry.key}');
      expect(diagnostics.single['requestId'], 'server-request-id');
    }
  });

  test('setMode 将无响应错误归类为网络错误且不记录请求体', () async {
    final diagnostics = <Map<String, Object?>>[];
    final exception = await _setModeFailure(
      networkError: true,
      diagnostics: diagnostics,
    );

    expect(exception.message, '网络连接失败，请检查网络后重试');
    expect(exception.httpStatus, isNull);
    expect(diagnostics, hasLength(1));
    expect(diagnostics.single['errorCode'], 'network_error');
    expect(diagnostics.single['route'], '/ai/permissions/mode');
    expect(diagnostics.single.containsKey('body'), isFalse);
    expect(diagnostics.single.containsKey('token'), isFalse);
  });
}

Future<AiPersonalDataPermissionException> _setModeFailure({
  int? statusCode,
  String? message,
  bool networkError = false,
  required List<Map<String, Object?>> diagnostics,
}) async {
  final dio = Dio(BaseOptions(baseUrl: 'http://test/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        options.headers['X-Request-ID'] = 'client-request-id';
        final response = networkError
            ? null
            : Response<dynamic>(
                requestOptions: options,
                statusCode: statusCode,
                data: <String, String>{
                  'code': 'server_error_$statusCode',
                  if (message != null) 'message': message,
                  'request_id': 'server-request-id',
                },
              );
        handler.reject(
          DioException(
            requestOptions: options,
            response: response,
            type: networkError
                ? DioExceptionType.connectionError
                : DioExceptionType.badResponse,
            error: networkError ? 'offline' : null,
          ),
        );
      },
    ),
  );

  final service = AiPersonalDataPermissionService(
    dio,
    diagnosticWriter: ({
      required route,
      required durationMs,
      required httpStatus,
      required errorCode,
      required requestId,
    }) async {
      diagnostics.add({
        'route': route,
        'durationMs': durationMs,
        'httpStatus': httpStatus,
        'errorCode': errorCode,
        'requestId': requestId,
      });
    },
  );

  try {
    await service.setMode(AiAgentPermissionMode.trusted);
  } on AiPersonalDataPermissionException catch (error) {
    // setMode 的诊断写入是 fire-and-forget，给微任务队列一个机会完成。
    await Future<void>.delayed(Duration.zero);
    return error;
  }
  fail('setMode 应该返回 AiPersonalDataPermissionException');
}
