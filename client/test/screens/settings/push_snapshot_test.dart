import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/push_settings_service.dart';

void main() {
  group('resolveRemotePushStatus 纯函数测试', () {
    test('未开启或不支持平台推导为 disabled', () {
      const snapshot1 = RemotePushSnapshot(
        supported: false,
        optedIn: true,
        notificationsEnabled: true,
        registrationId: 'reg123',
        aliasState: 'active',
        privateChannelExists: true,
        privateChannelBlocked: false,
      );
      expect(resolveRemotePushStatus(snapshot1), ResolvedPushStatus.disabled);

      const snapshot2 = RemotePushSnapshot(
        supported: true,
        optedIn: false,
        notificationsEnabled: true,
        registrationId: 'reg123',
        aliasState: 'active',
        privateChannelExists: true,
        privateChannelBlocked: false,
      );
      expect(resolveRemotePushStatus(snapshot2), ResolvedPushStatus.disabled);
    });

    test('已开启但原生诊断抛出异常推导为 diagnosticsUnavailable', () {
      const snapshot = RemotePushSnapshot(
        supported: true,
        optedIn: true,
        notificationsEnabled: false,
        registrationId: null,
        aliasState: null,
        privateChannelExists: false,
        privateChannelBlocked: false,
        diagnosticsAvailable: false,
        diagnosticsError: 'MethodChannel exception',
      );
      expect(resolveRemotePushStatus(snapshot),
          ResolvedPushStatus.diagnosticsUnavailable);
    });

    test('已开启但权限被拒绝推导为 permissionDenied', () {
      const snapshot = RemotePushSnapshot(
        supported: true,
        optedIn: true,
        notificationsEnabled: false,
        registrationId: 'reg123',
        aliasState: 'active',
        privateChannelExists: true,
        privateChannelBlocked: false,
      );
      expect(resolveRemotePushStatus(snapshot),
          ResolvedPushStatus.permissionDenied);
    });

    test('已开启但 RegistrationID 缺失推导为 registrationFailed', () {
      const snapshot = RemotePushSnapshot(
        supported: true,
        optedIn: true,
        notificationsEnabled: true,
        registrationId: null,
        aliasState: 'active',
        privateChannelExists: true,
        privateChannelBlocked: false,
      );
      expect(resolveRemotePushStatus(snapshot),
          ResolvedPushStatus.registrationFailed);
    });

    test('兼容旧 Alias 待绑定状态但不阻塞 RegistrationID 推送', () {
      const snapshot = RemotePushSnapshot(
        supported: true,
        optedIn: true,
        notificationsEnabled: true,
        registrationId: 'reg123',
        aliasState: 'pending_bind',
        privateChannelExists: true,
        privateChannelBlocked: false,
      );
      expect(resolveRemotePushStatus(snapshot), ResolvedPushStatus.ready);
    });

    test('已开启但私信渠道未建立推导为 channelUnavailable', () {
      const snapshot = RemotePushSnapshot(
        supported: true,
        optedIn: true,
        notificationsEnabled: true,
        registrationId: 'reg123',
        aliasState: 'active',
        privateChannelExists: false,
        privateChannelBlocked: false,
      );
      expect(resolveRemotePushStatus(snapshot),
          ResolvedPushStatus.channelUnavailable);
    });

    test('已开启但私信渠道被屏蔽推导为 channelBlocked', () {
      const snapshot = RemotePushSnapshot(
        supported: true,
        optedIn: true,
        notificationsEnabled: true,
        registrationId: 'reg123',
        aliasState: 'active',
        privateChannelExists: true,
        privateChannelBlocked: true,
      );
      expect(
          resolveRemotePushStatus(snapshot), ResolvedPushStatus.channelBlocked);
    });

    test('全部条件满足推导为 ready', () {
      const snapshot = RemotePushSnapshot(
        supported: true,
        optedIn: true,
        notificationsEnabled: true,
        registrationId: 'reg123',
        aliasState: 'active',
        privateChannelExists: true,
        privateChannelBlocked: false,
      );
      expect(resolveRemotePushStatus(snapshot), ResolvedPushStatus.ready);
    });
  });
}
