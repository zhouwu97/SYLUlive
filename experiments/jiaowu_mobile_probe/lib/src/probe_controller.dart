import 'package:flutter/foundation.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

import 'jiaowu_gateway.dart';

enum ProbeStatus { idle, loading, success, error }

/// 将教务异常转换成页面可展示的安全摘要，不保存密码、Cookie 或原始响应。
final class ProbeController extends ChangeNotifier {
  ProbeController(this.gateway);

  final JiaowuGateway gateway;
  ProbeStatus status = ProbeStatus.idle;
  String operation = '等待操作';
  String message = '可先执行网络诊断，再登录探测 Profile、课表或成绩。';
  String? errorCode;
  SafeTransportDiagnostic? diagnostic;
  bool _disposed = false;

  SessionState get sessionState => gateway.sessionState;
  bool get isBusy => status == ProbeStatus.loading;
  bool get isAuthenticated => sessionState == SessionState.authenticated;

  Future<void> login({
    required String studentId,
    required String password,
  }) async {
    _begin('登录');
    try {
      final result = await gateway.login(
        studentId: studentId.trim(),
        password: password,
      );
      switch (result) {
        case LoginSuccess():
          _success('登录', '已建立认证会话');
        case InvalidCredentials(:final message):
          _error('登录', 'INVALID_CREDENTIALS', message);
        case CaptchaRequired(:final message):
          _error('登录', 'CAPTCHA_REQUIRED', message);
        case LoginPageChanged(:final message):
          _error('登录', 'LOGIN_PAGE_CHANGED', message);
        case NetworkUnavailable(:final message, :final cause):
          _error(
            '登录',
            cause?.code ?? 'REMOTE_SYSTEM_UNAVAILABLE',
            message,
            diagnostic: cause?.diagnostic,
          );
      }
    } catch (error) {
      _handleError('登录', error);
    }
  }

  Future<void> getProfile() async {
    _begin('Profile');
    try {
      await gateway.getProfile();
      _success('Profile', 'Profile: OK');
    } catch (error) {
      _handleError('Profile', error);
    }
  }

  Future<void> getCourses({
    required String year,
    required String semester,
  }) async {
    final request = _validate(year: year, semester: semester);
    if (request == null) return;
    _begin('课表');
    try {
      final result = await gateway.getCourses(
        year: request.year,
        semester: request.semester,
      );
      final source = result.source == CourseSource.desktop
          ? 'desktop'
          : 'mobile';
      _success('课表', 'Courses: ${result.courses.length} records / $source');
    } catch (error) {
      _handleError('课表', error);
    }
  }

  Future<void> getGrades({
    required String year,
    required String semester,
  }) async {
    final request = _validate(year: year, semester: semester);
    if (request == null) return;
    _begin('成绩');
    try {
      final result = await gateway.getGrades(
        year: request.year,
        semester: request.semester,
      );
      final empty = result.validEmpty ? ' / valid empty' : '';
      _success(
        '成绩',
        'Grades: ${result.grades.length} records / ${result.pages} pages$empty',
      );
    } catch (error) {
      _handleError('成绩', error);
    }
  }

  Future<void> diagnoseNetwork({bool insecureTls = false}) async {
    final label = insecureTls ? '网络诊断（Debug insecure TLS）' : '网络诊断';
    _begin(label);
    try {
      final result = await gateway.diagnoseNetwork(insecureTls: insecureTls);
      final summary = _networkSummary(result);
      if (result.succeeded) {
        _success(label, summary);
        return;
      }

      final error = result.error;
      final code = error?.code ?? 'CONNECTION_FAILED';
      _error(label, code, summary, diagnostic: error?.diagnostic);
    } catch (error) {
      _handleError(label, error);
    }
  }

  _AcademicRequest? _validate({
    required String year,
    required String semester,
  }) {
    final normalizedYear = year.trim();
    final parsedSemester = int.tryParse(semester.trim());
    if (parsedSemester == null) {
      _error('参数', 'INVALID_ACADEMIC_REQUEST', '学期必须是 3 或 12');
      return null;
    }
    try {
      JiaowuRequestValidator.validateAcademicRequest(
        year: normalizedYear,
        semester: parsedSemester,
      );
    } on ArgumentError catch (error) {
      _error('参数', 'INVALID_ACADEMIC_REQUEST', error.message.toString());
      return null;
    }
    return _AcademicRequest(normalizedYear, parsedSemester);
  }

  void _begin(String nextOperation) {
    status = ProbeStatus.loading;
    operation = nextOperation;
    errorCode = null;
    diagnostic = null;
    message = '正在执行$nextOperation...';
    _notify();
  }

  void _success(String nextOperation, String nextMessage) {
    status = ProbeStatus.success;
    operation = nextOperation;
    errorCode = null;
    diagnostic = null;
    message = nextMessage;
    _notify();
  }

  void _error(
    String nextOperation,
    String code,
    String nextMessage, {
    SafeTransportDiagnostic? diagnostic,
  }) {
    status = ProbeStatus.error;
    operation = nextOperation;
    errorCode = code;
    this.diagnostic = diagnostic;
    message = nextMessage;
    _notify();
  }

  void _handleError(String nextOperation, Object error) {
    if (error is JiaowuException) {
      _error(
        nextOperation,
        error.code,
        error.message,
        diagnostic: error.diagnostic,
      );
    } else {
      _error(nextOperation, 'UNEXPECTED_ERROR', '操作失败，请检查输入或网络连接');
    }
  }

  String _networkSummary(JiaowuNetworkProbeResult result) {
    final dns = result.dnsSucceeded ? 'OK' : 'FAILED';
    final https = result.httpsSucceeded ? 'OK' : 'FAILED';
    final csrf = result.csrfSucceeded ? 'OK' : 'FAILED';
    final status = result.httpStatus == null
        ? ''
        : '\nHTTP status: ${result.httpStatus}';
    return 'DNS: $dns\n'
        'IPv4: ${result.ipv4Count}\n'
        'IPv6: ${result.ipv6Count}\n'
        'HTTPS: $https\n'
        'CSRF: $csrf$status';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    gateway.close();
    super.dispose();
  }
}

final class _AcademicRequest {
  const _AcademicRequest(this.year, this.semester);
  final String year;
  final int semester;
}
