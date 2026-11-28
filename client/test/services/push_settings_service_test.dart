import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/services/push_settings_service.dart';
import 'package:shenliyuan/platform/ohos/ohos_push_client.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('鸿蒙私信点击只在开启推送后投递，关闭后丢弃迟到事件', () async {
    const sdk = MethodChannel('jpush');
    const native = MethodChannel('shenliyuan/private_message_notifications');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(sdk, (call) async {
      calls.add(call.method);
      return call.method == 'getRegistrationId' ? 'test-rid' : true;
    });
    messenger.setMockMethodCallHandler(native, (call) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(sdk, null);
      messenger.setMockMethodCallHandler(native, null);
      sdk.setMethodCallHandler(null);
    });
    final client = OhosPushClient();
    final clicks = <Map<String, dynamic>>[];
    client.setHandlers(onOpenNotification: (event) async => clicks.add(event));
    Future<void> click() => messenger.handlePlatformMessage(sdk.name,
      sdk.codec.encodeMethodCall(const MethodCall('onClickMessage',
        {'extras': '{"type":"private_message","conversation_id":17}'})), (_) {});
    await click();
    expect(await client.getRegistrationId(), isNull);
    expect(calls, isEmpty);
    client.setup(appKey: 'test', channel: 'test', production: false, debug: false);
    expect(await client.getRegistrationId(), 'test-rid');
    await click();
    await client.setPushOptIn(false);
    await click();
    expect(clicks.single['extras']['conversation_id'], 17);
    expect(calls, contains('stopPush'));
  });

  test('用户开启推送时立即调用设备注册回调', () async {
    AppPreferencesStore.setMockInitialValues({});
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
    AppPreferencesStore.setMockInitialValues({});
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
