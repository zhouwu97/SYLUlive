import 'package:flutter_test/flutter_test.dart';

import 'package:shenliyuan/services/account_session_cleanup_coordinator.dart';

void main() {
  test('所有上下文先同步清空，异步取消失败不阻断退出', () async {
    final coordinator = AccountSessionCleanupCoordinator();
    final events = <String>[];
    final ownerA = Object();
    final ownerB = Object();

    coordinator.register(ownerA, () async {
      events.add('a-cleared');
      await Future<void>.delayed(Duration.zero);
      events.add('a-cancelled');
      throw StateError('cancel failed');
    });
    coordinator.register(ownerB, () {
      events.add('b-cleared');
    });

    await coordinator.closeCurrentSession();

    expect(events.take(2).toSet(), {'a-cleared', 'b-cleared'});
    expect(events, contains('a-cancelled'));
  });
}
