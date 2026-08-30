import 'dart:async';

/// 对同一业务动作合并并发调用，避免快速点击触发多次写请求。
///
/// key 必须代表一个具体动作（例如 post:12:reply），不同动作使用不同 key，
/// 才能保留合法的并行操作。相同 key 的调用共享同一个 Future，底层请求只发一次。
class AsyncActionGuard {
  final Map<String, Future<Object?>> _inFlight = <String, Future<Object?>>{};

  bool isRunning(String key) => _inFlight.containsKey(key);

  Future<T> run<T>(String key, Future<T> Function() action) {
    final normalizedKey = key.trim();
    if (normalizedKey.isEmpty) {
      throw ArgumentError.value(key, 'key', '动作键不能为空');
    }

    final existing = _inFlight[normalizedKey];
    if (existing != null) {
      return existing.then<T>((value) => value as T);
    }

    final future = Future<T>.sync(action);
    _inFlight[normalizedKey] = future;
    // 显式消费清理链上的异常，避免调用方只等待主 Future 时产生未处理异常。
    unawaited(future.then<void>(
      (_) => _release(normalizedKey, future),
      onError: (Object _, StackTrace __) => _release(normalizedKey, future),
    ));
    return future;
  }

  void _release(String key, Future<Object?> future) {
    if (identical(_inFlight[key], future)) {
      _inFlight.remove(key);
    }
  }
}
