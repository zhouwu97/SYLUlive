import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/app_platform.dart';
import 'package:shenliyuan/platform/scan/scan_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.sylulive.harmony/scan_test');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('扫码通道传递类型并返回原始结果', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      received = call;
      return 'sylulive://competition/42';
    });

    final service = OhosScanService(channel: channel);
    expect(service.platform, AppPlatform.ohos);
    expect(service.isSupported, isTrue);
    expect(
        await service.scan(kind: ScanKind.qrcode), 'sylulive://competition/42');
    expect(received?.method, 'scan');
    expect((received?.arguments as Map)['kind'], 'qrcode');
  });

  test('用户取消扫码返回 null', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'scan_cancelled');
    });

    expect(await OhosScanService(channel: channel).scan(), isNull);
  });

  test('真实扫码错误继续抛出', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'scan_failed', message: '设备不可用');
    });

    expect(
      () => OhosScanService(channel: channel).scan(),
      throwsA(isA<PlatformException>()),
    );
  });
}
