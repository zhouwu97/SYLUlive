import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

/// UI 和业务层可处理的教务失败类别。
enum AcademicFailureKind {
  invalidCredentials,
  captchaRequired,
  captchaExpired,
  sessionExpired,
  unauthenticated,
  network,
  protocolChanged,
  courseUnavailable,
  gradeUnavailable,
  unexpected,
}

/// 已脱敏的教务错误。
///
/// 不保留 password、Cookie、响应体或原始异常；排障信息只能来自 POC
/// 客户端提供的 [SafeTransportDiagnostic] 白名单字段。
final class AcademicFailure implements Exception {
  const AcademicFailure({
    required this.kind,
    required this.message,
    required this.code,
    this.diagnostic,
  });

  factory AcademicFailure.fromException(Object error) {
    if (error is AcademicFailure) return error;
    if (error is JiaowuException) {
      return AcademicFailure(
        kind: _kindForException(error),
        message: error.message,
        code: error.code,
        diagnostic: error.diagnostic,
      );
    }
    return const AcademicFailure(
      kind: AcademicFailureKind.unexpected,
      message: '教务操作失败，请稍后重试',
      code: 'ACADEMIC_UNEXPECTED',
    );
  }

  /// 将不抛异常的登录结果统一为 UI 可渲染的失败。
  factory AcademicFailure.fromLoginResult(LoginResult result) {
    return switch (result) {
      LoginSuccess() => throw ArgumentError('成功结果不能转换为失败'),
      InvalidCredentials(:final message) => AcademicFailure(
          kind: AcademicFailureKind.invalidCredentials,
          message: message,
          code: 'INVALID_CREDENTIALS',
        ),
      CaptchaRequired(:final message) => AcademicFailure(
          kind: AcademicFailureKind.captchaRequired,
          message: message,
          code: 'CAPTCHA_REQUIRED',
        ),
      CaptchaExpired(:final message) => AcademicFailure(
          kind: AcademicFailureKind.captchaExpired,
          message: message,
          code: 'CAPTCHA_EXPIRED',
        ),
      LoginPageChanged(:final message) => AcademicFailure(
          kind: AcademicFailureKind.protocolChanged,
          message: message,
          code: 'LOGIN_PAGE_CHANGED',
        ),
      NetworkUnavailable(:final message, :final cause) => _fromLoginNetwork(
          message,
          cause,
        ),
    };
  }

  final AcademicFailureKind kind;
  final String message;
  final String code;
  final SafeTransportDiagnostic? diagnostic;

  bool get isRetryable => switch (kind) {
        AcademicFailureKind.invalidCredentials => false,
        AcademicFailureKind.captchaRequired => true,
        AcademicFailureKind.captchaExpired => true,
        AcademicFailureKind.sessionExpired => true,
        AcademicFailureKind.unauthenticated => true,
        AcademicFailureKind.network => true,
        AcademicFailureKind.protocolChanged => false,
        AcademicFailureKind.courseUnavailable => true,
        AcademicFailureKind.gradeUnavailable => true,
        AcademicFailureKind.unexpected => true,
      };

  @override
  String toString() => '$code: $message';

  static AcademicFailureKind _kindForException(JiaowuException error) {
    if (error is InvalidCredentialsException) {
      return AcademicFailureKind.invalidCredentials;
    }
    if (error is CaptchaRequiredException) {
      return AcademicFailureKind.captchaRequired;
    }
    if (error is CaptchaExpiredException) {
      return AcademicFailureKind.captchaExpired;
    }
    if (error is SessionExpiredException) {
      return AcademicFailureKind.sessionExpired;
    }
    if (error is UnauthenticatedException) {
      return AcademicFailureKind.unauthenticated;
    }
    if (error is CourseNotOpenException) {
      return AcademicFailureKind.courseUnavailable;
    }
    if (error is GradeNotOpenException) {
      return AcademicFailureKind.gradeUnavailable;
    }
    if (error is ProtocolChangedException ||
        error is ParseException ||
        error is LoginPageChangedException) {
      return AcademicFailureKind.protocolChanged;
    }
    if (error is NetworkException) return AcademicFailureKind.network;
    return AcademicFailureKind.unexpected;
  }

  static AcademicFailure _fromLoginNetwork(String message, Object? cause) {
    final mapped = cause is JiaowuException
        ? AcademicFailure.fromException(cause)
        : const AcademicFailure(
            kind: AcademicFailureKind.network,
            message: '教务登录失败，请检查网络连接',
            code: 'NETWORK_ERROR',
          );
    return AcademicFailure(
      kind: mapped.kind == AcademicFailureKind.unexpected
          ? AcademicFailureKind.network
          : mapped.kind,
      message: message,
      code: mapped.code,
      diagnostic: mapped.diagnostic,
    );
  }
}
