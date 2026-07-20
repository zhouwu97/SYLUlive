import 'dart:async';

import 'package:flutter/foundation.dart';

typedef AccountSessionCleanup = FutureOr<void> Function();

/// 统一协调退出与换号前的内存上下文关闭。
class AccountSessionCleanupCoordinator {
  AccountSessionCleanupCoordinator();

  static final AccountSessionCleanupCoordinator instance =
      AccountSessionCleanupCoordinator();

  final Map<Object, AccountSessionCleanup> _callbacks = {};

  void register(Object owner, AccountSessionCleanup callback) {
    _callbacks[owner] = callback;
  }

  void unregister(Object owner) {
    _callbacks.remove(owner);
  }

  Future<void> closeCurrentSession() async {
    final pending = <Future<void>>[];
    for (final callback in List<AccountSessionCleanup>.of(_callbacks.values)) {
      try {
        final result = callback();
        if (result is Future) pending.add(result.then<void>((_) {}));
      } catch (error) {
        debugPrint('账号上下文清理失败: ${error.runtimeType}');
      }
    }
    if (pending.isEmpty) return;
    await Future.wait(
      pending.map((future) async {
        try {
          await future;
        } catch (error) {
          debugPrint('账号上下文异步清理失败: ${error.runtimeType}');
        }
      }),
    );
  }
}
