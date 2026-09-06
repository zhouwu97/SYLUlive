import 'package:cookie_jar/cookie_jar.dart';

import 'session_state.dart';

/// 只保留当前会话状态，不在实验包中持久化密码或 Cookie。
final class JiaowuSession {
  SessionState state = SessionState.unauthenticated;
  String? studentId;

  void beginLogin(String id) {
    studentId = id;
    state = SessionState.authenticating;
  }

  void markAuthenticated() {
    state = SessionState.authenticated;
  }

  void awaitCaptcha(String id) {
    studentId = id;
    state = SessionState.awaitingCaptcha;
  }

  void markExpired() {
    state = SessionState.expired;
  }

  /// 只清理内存状态，适用于保留当前 HTTP Session 的中间流程，例如验证码。
  void clearState() {
    studentId = null;
    state = SessionState.unauthenticated;
  }

  /// 清理完整教务会话，确保下一次登录不会复用旧账号 Cookie。
  Future<void> resetSession(CookieJar cookieJar) async {
    await cookieJar.deleteAll();
    clearState();
  }

  /// 兼容早期 POC 调用方；新代码必须明确选择 [clearState] 或 [resetSession]。
  @Deprecated('Use clearState or resetSession instead.')
  void clear() => clearState();
}
