import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/services/push_settings_service.dart';

void main() {
  test('用户开启推送时立即调用设备注册回调', () async {
    SharedPreferences.setMockInitialValues({});
    final auth = AuthProvider(Dio(), loadStoredAuth: false);
    var registrationCalled = false;
    PushSettingsService.configureRemoteRegistration((_) async {
      registrationCalled = true;
      return const RemotePushEnableResult(
        permissionGranted: true,
        registrationSucceeded: true,
        message: '已开启远程消息推送',
      );
    });
    addTearDown(auth.dispose);

    final result = await PushSettingsService.enableAndRegister(auth);

    expect(registrationCalled, isTrue);
    expect(result.registrationSucceeded, isTrue);
    expect(await PushSettingsService.isEnabled(), isTrue);
  });
}
