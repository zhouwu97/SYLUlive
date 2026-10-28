import '../providers/auth_provider.dart';

/// 回复消费绑定账号登录周期，资料刷新不应让已成功的请求失效。
class ReplyNotificationSession {
  ReplyNotificationSession.capture(AuthProvider auth)
      : accountId = auth.user?.id,
        accountEpoch = _epoch(auth);

  final int? accountId;
  final int accountEpoch;

  bool isCurrent(AuthProvider auth) =>
      accountId != null &&
      auth.isLoggedIn &&
      auth.user?.id == accountId &&
      _epoch(auth) == accountEpoch;

  static int _epoch(AuthProvider auth) {
    try {
      return auth.accountSessionEpoch;
    } catch (_) {
      // 兼容仍只暴露 sessionGeneration 的 AuthProvider 适配器。
      return auth.sessionGeneration;
    }
  }
}
