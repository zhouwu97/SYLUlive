import 'package:jiaowu_dart_poc/jiaowu_dart.dart';
import 'package:dio/dio.dart';

import 'academic_provider.dart';

/// UI 和业务层可处理的教务失败类别。
enum AcademicFailureKind {
  invalidCredentials,
  accountRejected,
  accountRestricted,
  captchaRequired,
  captchaExpired,
  challengeRejected,
  authRejectedAmbiguous,
  sessionExpired,
  unauthenticated,
  identityMismatch,
  disconnected,
  localCredentialRequired,
  network,
  schoolUnavailable,
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
    if (error is DioException) {
      final unavailable = (error.response?.statusCode ?? 0) >= 500;
      return AcademicFailure(
        kind: unavailable ? AcademicFailureKind.schoolUnavailable : AcademicFailureKind.network,
        message: unavailable ? '学校服务暂时不可用，请稍后重试' : '教务网络连接失败，请稍后重试',
        code: unavailable ? 'SCHOOL_UNAVAILABLE' : 'NETWORK_ERROR',
      );
    }
    if (error is AcademicAuthFailure) {
      return AcademicFailure(
        kind: _kindForAuthFailure(error.type),
        message: error.message,
        code: 'ACADEMIC_AUTH_${error.type.name.toUpperCase()}',
      );
    }
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
        AcademicFailureKind.accountRejected => false,
        AcademicFailureKind.accountRestricted => false,
        AcademicFailureKind.captchaRequired => true,
        AcademicFailureKind.captchaExpired => true,
        AcademicFailureKind.challengeRejected => true,
        AcademicFailureKind.authRejectedAmbiguous => true,
        AcademicFailureKind.sessionExpired => true,
        AcademicFailureKind.unauthenticated => true,
        AcademicFailureKind.identityMismatch => false,
        AcademicFailureKind.disconnected => false,
        AcademicFailureKind.localCredentialRequired => false,
        AcademicFailureKind.network => true,
        AcademicFailureKind.schoolUnavailable => true,
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
    if (error is NetworkException) {
      return error.code == 'SCHOOL_UNAVAILABLE'
          ? AcademicFailureKind.schoolUnavailable : AcademicFailureKind.network;
    }
    return AcademicFailureKind.unexpected;
  }

  static AcademicFailureKind _kindForAuthFailure(AcademicAuthFailureType type) {
    return switch (type) {
      AcademicAuthFailureType.credentialMissing =>
        AcademicFailureKind.localCredentialRequired,
      AcademicAuthFailureType.credentialRejected =>
        AcademicFailureKind.invalidCredentials,
      AcademicAuthFailureType.accountRejected =>
        AcademicFailureKind.accountRejected,
      AcademicAuthFailureType.accountRestricted =>
        AcademicFailureKind.accountRestricted,
      AcademicAuthFailureType.challengeRequired =>
        AcademicFailureKind.captchaRequired,
      AcademicAuthFailureType.challengeRejected =>
        AcademicFailureKind.challengeRejected,
      AcademicAuthFailureType.authRejectedAmbiguous =>
        AcademicFailureKind.authRejectedAmbiguous,
      AcademicAuthFailureType.sessionExpired => AcademicFailureKind.sessionExpired,
      AcademicAuthFailureType.identityMismatch => AcademicFailureKind.identityMismatch,
    };
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
