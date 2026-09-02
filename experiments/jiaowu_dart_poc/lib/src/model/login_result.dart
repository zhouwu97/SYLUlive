import '../error/jiaowu_exception.dart';

/// 登录结果使用可扩展的分类类型，不把所有状态压扁成 bool。
sealed class LoginResult {
  const LoginResult();
}

final class LoginSuccess extends LoginResult {
  const LoginSuccess({required this.studentId, required this.cookieNames});

  final String studentId;

  /// 仅保留名称用于诊断，绝不暴露 Cookie 值。
  final Set<String> cookieNames;
}

final class InvalidCredentials extends LoginResult {
  const InvalidCredentials({this.message = '教务账号或密码错误'});

  final String message;
}

final class CaptchaRequired extends LoginResult {
  const CaptchaRequired({this.message = '教务系统要求输入验证码'});

  final String message;
}

final class CaptchaExpired extends LoginResult {
  const CaptchaExpired({this.message = '验证码会话已失效，请重新登录'});

  final String message;
}

final class LoginPageChanged extends LoginResult {
  const LoginPageChanged({required this.message, this.cause});

  final String message;
  final JiaowuException? cause;
}

final class NetworkUnavailable extends LoginResult {
  const NetworkUnavailable({required this.message, this.cause});

  final String message;
  final JiaowuException? cause;
}
