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

  void markExpired() {
    state = SessionState.expired;
  }

  void clear() {
    studentId = null;
    state = SessionState.unauthenticated;
  }
}
