import 'package:flutter_test/flutter_test.dart';
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
      },
    );
  });
}
