import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/async_action_guard.dart';

void main() {
  test('同一动作的快速调用共享一个 Future，底层只执行一次', () async {
    final guard = AsyncActionGuard();
    final completer = Completer<int>();
    var calls = 0;

    final first = guard.run<int>('reply:7', () {
      calls++;
      return completer.future;
    });
    final second = guard.run<int>('reply:7', () async {
      calls++;
      return 99;
    });

    expect(guard.isRunning('reply:7'), isTrue);
    expect(calls, 1);
    completer.complete(42);
    expect(await first, 42);
    expect(await second, 42);
    expect(guard.isRunning('reply:7'), isFalse);
  });

  test('不同动作允许并行，失败后可以重新发起', () async {
    final guard = AsyncActionGuard();
    final firstCompleter = Completer<void>();
    final secondCompleter = Completer<void>();

    final first = guard.run<void>('post:1', () => firstCompleter.future);
    final second = guard.run<void>('post:2', () => secondCompleter.future);
    expect(guard.isRunning('post:1'), isTrue);
    expect(guard.isRunning('post:2'), isTrue);

    firstCompleter.complete();
    secondCompleter.complete();
    await Future.wait([first, second]);

    expect(guard.isRunning('post:1'), isFalse);
    expect(guard.isRunning('post:2'), isFalse);

    var retries = 0;
    await expectLater(
      guard.run<void>('post:3', () async {
        retries++;
        throw StateError('network');
      }),
      throwsStateError,
    );
    expect(guard.isRunning('post:3'), isFalse);
    await guard.run<void>('post:3', () async => retries++);
    expect(retries, 2);
  });
}
