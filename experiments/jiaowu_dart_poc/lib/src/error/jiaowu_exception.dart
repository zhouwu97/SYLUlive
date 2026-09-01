import '../network/safe_transport_diagnostic.dart';

/// 教务协议错误基类。
sealed class JiaowuException implements Exception {
  const JiaowuException(this.message, this.code, {this.cause});

  final String message;
  final String code;
  final Object? cause;
  SafeTransportDiagnostic? get diagnostic => null;

  @override
  String toString() => '$code: $message';
}

final class InvalidCredentialsException extends JiaowuException {
  const InvalidCredentialsException({String message = '教务账号或密码错误'})
      : super(message, 'INVALID_CREDENTIALS');
}

final class SessionExpiredException extends JiaowuException {
  const SessionExpiredException({String message = '教务登录会话已失效'})
      : super(message, 'SESSION_EXPIRED');
}

final class UnauthenticatedException extends JiaowuException {
  const UnauthenticatedException({String message = '当前没有已认证的教务会话'})
      : super(message, 'UNAUTHENTICATED');
}

final class CaptchaRequiredException extends JiaowuException {
  const CaptchaRequiredException({String message = '教务系统要求输入验证码'})
      : super(message, 'CAPTCHA_REQUIRED');
}

final class LoginPageChangedException extends JiaowuException {
  const LoginPageChangedException({
    String message = '学校登录页面可能发生变化，请稍后重试或联系管理员',
    Object? cause,
  }) : super(message, 'LOGIN_PAGE_CHANGED', cause: cause);
}

final class NetworkException extends JiaowuException {
  const NetworkException({
    String message = '学校教务系统暂时不可用，请稍后再试',
    String code = 'REMOTE_SYSTEM_UNAVAILABLE',
    Object? cause,
    this.diagnostic,
  }) : super(message, code, cause: cause);

  final SafeTransportDiagnostic? diagnostic;
}

final class RequestTimeoutException extends NetworkException {
  const RequestTimeoutException({
    String message = '教务请求超时',
    Object? cause,
    SafeTransportDiagnostic? diagnostic,
  }) : super(
          message: message,
          code: 'REQUEST_TIMEOUT',
          cause: cause,
          diagnostic: diagnostic,
        );
}

final class RemoteMaintenanceException extends NetworkException {
  const RemoteMaintenanceException({String message = '教务系统可能正在维护'})
      : super(message: message, code: 'REMOTE_MAINTENANCE');
}

final class ParseException extends JiaowuException {
  const ParseException({
    String message = '教务响应无法解析',
    String code = 'PARSE_ERROR',
    Object? cause,
  }) : super(message, code, cause: cause);
}

final class ProtocolChangedException extends ParseException {
  const ProtocolChangedException({
    String message = '学校教务接口结构可能发生变化',
    Object? cause,
  }) : super(message: message, code: 'PROTOCOL_CHANGED', cause: cause);
}

final class CourseNotOpenException extends JiaowuException {
  const CourseNotOpenException({String message = '当前学期课表暂未排课'})
      : super(message, 'COURSE_NOT_OPEN');
}

final class GradeNotOpenException extends JiaowuException {
  const GradeNotOpenException({String message = '当前学期成绩暂未开放'})
      : super(message, 'GRADE_NOT_OPEN');
}
