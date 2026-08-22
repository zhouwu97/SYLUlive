import 'package:dio/dio.dart';

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
  AiPersonalDataPermissionService(this._dio);

  final Dio _dio;

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
  const AiPersonalDataPermissionException(this.message);

  final String message;

  @override
  String toString() => message;
}
