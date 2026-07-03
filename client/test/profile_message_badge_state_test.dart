import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/profile_screen.dart';

void main() {
  test('私信红点只跟私信未读数有关', () {
    final state = profileMessageEntryState(
      unreadMessageCount: 0,
      unreadNotificationCount: 3,
    );

    expect(state.showPrivateBadge, isFalse);
    expect(state.privateSubtitle, '查看私信');
    expect(state.showNotificationBadge, isTrue);
    expect(state.notificationSubtitle, '3条新通知');
  });

  test('通知红点只跟通知未读数有关', () {
    final state = profileMessageEntryState(
      unreadMessageCount: 2,
      unreadNotificationCount: 0,
    );

    expect(state.showPrivateBadge, isTrue);
    expect(state.privateSubtitle, '2条新私信');
    expect(state.showNotificationBadge, isFalse);
    expect(state.notificationSubtitle, isNull);
  });
}
