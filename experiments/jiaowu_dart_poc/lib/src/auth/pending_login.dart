/// 等待验证码的短生命周期登录材料。
///
/// 只存在内存中，不能序列化、持久化或写入日志。Dart String 无法主动清零，
/// 因此通过短 TTL、完成/取消立即释放引用来缩短密码生命周期。
final class PendingLogin {
  const PendingLogin({
    required this.studentId,
    required this.password,
    required this.csrfToken,
    required this.createdAt,
  });

  final String studentId;
  final String password;
  final String csrfToken;
  final DateTime createdAt;

  PendingLogin refreshedAt(DateTime timestamp) {
    return PendingLogin(
      studentId: studentId,
      password: password,
      csrfToken: csrfToken,
      createdAt: timestamp,
    );
  }
}
