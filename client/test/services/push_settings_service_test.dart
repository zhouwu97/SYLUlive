import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/services/push_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('原生推送开关在开启时写入 true', () async {
    const channel = MethodChannel('shenliyuan/private_message_notifications');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await PushSettingsService.setNativePushOptIn(true);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'setPushOptIn');
    expect(calls.single.arguments, {'enabled': true});
  });

  test('同一账号的注册请求共享同一个 Future', () async {
    SharedPreferences.setMockInitialValues({});
    final auth = AuthProvider(Dio(), loadStoredAuth: false);
    var registrationCalls = 0;
    PushSettingsService.configureRemoteRegistration((_) async {
      registrationCalls++;
      await Future<void>.delayed(const Duration(milliseconds: 1));
      return const RemotePushEnableResult(
        permissionGranted: true,
        registrationSucceeded: true,
        message: '已开启远程消息推送',
      );
    });
    addTearDown(auth.dispose);

    final first = PushSettingsService.registerOnce(auth);
    final second = PushSettingsService.registerOnce(auth);

    expect(identical(first, second), isTrue);
    await Future.wait([first, second]);
    expect(registrationCalls, 1);
  });
}
