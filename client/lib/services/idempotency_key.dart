import 'dart:math';

/// 为一次用户确认动作生成短期幂等键。
///
/// 业务层应在一次动作的重试生命周期内复用返回值；不要为每次网络重试
/// 重新生成键，否则服务端无法判断“响应丢失后的同一次提交”。
String newIdempotencyKey([String prefix = 'action']) {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  String hex(int value) => value.toRadixString(16).padLeft(2, '0');
  final suffix = bytes.map(hex).join();
  return '${prefix.trim().isEmpty ? 'action' : prefix.trim()}-$suffix';
}

/// 幂等键与本次提交的关系，与服务端 middleware.IdempotencyMiddleware 状态机一一对应。
enum IdempotencyOutcome {
  /// 与幂等无关：原键仍代表同一次提交，内容不变时可原样重试。
  none,

  /// 这把键已经不能代表"同一次提交"，调用方必须丢弃它，下一次点击算新的一次操作。
  ///
  /// 覆盖三种终态：键被绑到另一份请求体（`idempotency_key_reused`）、
  /// 中途崩溃结果未知（`idempotency_request_failed`）、未决超时
  /// （`idempotency_request_expired`）。继续沿用只会让用户卡在同一个冲突里。
  exhausted,

  /// 同一请求仍在处理：必须保留原键等它出结果，不能另起一次造成重复。
  inProgress,
}

/// 由错误码判断幂等键还能不能继续用。
IdempotencyOutcome idempotencyOutcomeFor(String? code) {
  return switch (code) {
    'idempotency_key_reused' ||
    'idempotency_request_failed' ||
    'idempotency_request_expired' =>
      IdempotencyOutcome.exhausted,
    'idempotency_request_in_progress' => IdempotencyOutcome.inProgress,
    _ => IdempotencyOutcome.none,
  };
}

/// 幂等冲突的用户侧文案。
///
/// 服务端文案只说明现象（"Idempotency-Key 已用于不同请求"），用户看不出下一步。
/// 这类统一换成可执行的提示，其余情况透传调用方已有的文案。
String idempotencyUserMessage(String? code, String fallback) {
  return switch (code) {
    'idempotency_key_reused' =>
      '这次提交与上一次内容不同，请再点一次提交，会按新的一次处理',
    'idempotency_request_failed' || 'idempotency_request_expired' =>
      '上一次提交结果未知，请刷新确认后再提交一次',
    'idempotency_request_in_progress' => '上一次提交还在处理，请稍候',
    _ => fallback,
  };
}

/// 决定本次提交用哪把幂等键。
///
/// [pendingFingerprint] / [pendingKey] 是上一次**未确认送达**的请求身份。
/// 指纹一致才是"原样重试"——复用原键，服务端才能把响应丢失后的重试认成同一次操作；
/// 任何字段变化都算新的一次操作，换新键，否则服务端会按不同请求体拒绝。
///
/// 注意不能反过来规定"每次重试都生成新键"：那只是把幂等冲突换成重复创建。
String resolveIdempotencyKey({
  required String fingerprint,
  String? pendingFingerprint,
  String? pendingKey,
}) {
  if (pendingKey != null && pendingFingerprint == fingerprint) return pendingKey;
  return newIdempotencyKey();
}
