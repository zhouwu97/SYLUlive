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

    test('已开启且 Alias 待绑定推导为 configuring', () {
      const snapshot = RemotePushSnapshot(
        supported: true,
        optedIn: true,
        notificationsEnabled: true,
        registrationId: 'reg123',
        aliasState: 'pending_bind',
        privateChannelExists: true,
        privateChannelBlocked: false,
      );
      expect(resolveRemotePushStatus(snapshot), ResolvedPushStatus.configuring);
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
