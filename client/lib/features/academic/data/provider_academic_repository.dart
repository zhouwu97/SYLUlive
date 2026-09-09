import 'dart:typed_data';

import 'package:jiaowu_dart_poc/jiaowu_dart.dart' hide AcademicCapabilities;

import '../domain/academic_provider.dart';
import '../domain/academic_repository.dart';
import '../domain/academic_failure.dart';
import 'academic_provider_adapters.dart';

/// 统一 Provider 到历史教务仓储的兼容桥。
///
/// 现有页面仍使用 jiaowu_dart 的返回类型；桥接层把研究生原始响应转换为
/// normalized AcademicSchedule 后再映射回 RawCourse，协议细节不会进入 UI。
final class ProviderAcademicRepository implements AcademicRepository {
  ProviderAcademicRepository(this.provider);

  final AcademicProvider provider;
  AcademicLoginRequest? _pendingLogin;
  ImageCaptchaChallenge? _pendingChallenge;
  List<AcademicTerm>? _terms;
  bool _closed = false;

  @override
  AcademicSourceKind get sourceKind => AcademicSourceKind.local;

  @override
  AcademicCapabilities get capabilities => AcademicCapabilities(
        supportsProfile: provider is UndergraduateAcademicProvider || provider is GraduateAcademicProvider,
        supportsCourses: provider.capabilities.timetable,
        supportsGrades: provider.capabilities.grades,
        supportsGradeDetail: provider is UndergraduateAcademicProvider,
        supportsAcademicSituation: provider.capabilities.gpa,
        supportsCreditRequirements: provider is UndergraduateAcademicProvider,
      );

  @override
  SessionState get sessionState => _lastSessionState;
  SessionState _lastSessionState = SessionState.unauthenticated;

  @override
  String? get studentId => provider.identity.studentId;

  @override
  String get sourceName => provider.id.displayName;

  /// 返回学校真实学期列表，供课表选择器传递准确 providerTermId。
  Future<List<AcademicTerm>> fetchTerms() async {
    _ensureOpen();
    return _terms ??= await provider.fetchTerms();
  }

  /// Provider 的会话材料恢复已完成校验时，同步兼容仓储的状态。
  ///
  /// 各 Provider 的 restoreSession 已负责恢复并探活，桥接层不能再次发起
  /// 相同探活请求，否则冷启动会重复访问学校资料接口。
  void markSessionAuthenticated() {
    _ensureOpen();
    _lastSessionState = SessionState.authenticated;
    _terms = null;
  }

  @override
  Future<void> switchSource(AcademicSourceKind source) async {
    _ensureOpen();
    if (source != AcademicSourceKind.local) {
      throw StateError('Provider 适配器不支持切换到旧服务端代理');
    }
  }

  @override
  Future<LoginResult> login(
      {required String studentId, required String password}) async {
    _ensureOpen();
    _lastSessionState = SessionState.unauthenticated;
    _pendingLogin =
        AcademicLoginRequest(studentId: studentId.trim(), password: password);
    final result = await provider.login(_pendingLogin!);
    final mapped = await _mapLoginResult(result);
    if (mapped is LoginSuccess) {
      _lastSessionState = SessionState.authenticated;
      _pendingLogin = null;
    }
    return mapped;
  }

  @override
  Future<CaptchaChallenge> getCaptchaChallenge() async {
    _ensureOpen();
    final challenge = _pendingChallenge ?? await provider.prepareLogin();
    if (challenge is! ImageCaptchaChallenge) {
      throw const LoginPageChangedException(message: '当前教务 Provider 不需要验证码图片');
    }
    _pendingChallenge = challenge;
    return CaptchaChallenge(
      imageBytes: Uint8List.fromList(challenge.imageBytes),
      suggestedCode: challenge.suggestedCode,
      suggestionConfidence: challenge.suggestionConfidence,
    );
  }

  Future<CaptchaChallenge> refreshCaptchaChallenge() {
    _pendingChallenge = null;
    return getCaptchaChallenge();
  }

  @override
  Future<LoginResult> continueLoginWithCaptcha({required String code}) async {
    _ensureOpen();
    final pending = _pendingLogin;
    if (pending == null) {
      return const CaptchaExpired(message: '验证码登录会话已失效，请重新开始登录');
    }
    // 兼容仓储只允许当前 challenge 使用一次；Provider 抛出异常时也不
    // 留下旧图片，下一次显式登录必须重新准备验证码。
    final challengeId = _pendingChallenge?.challengeId;
    _pendingChallenge = null;
    final result = await provider.login(
      AcademicLoginRequest(
        studentId: pending.studentId,
        password: pending.password,
        captchaCode: code,
        challengeId: challengeId,
      ),
    );
    final mapped = await _mapLoginResult(result);
    if (mapped is LoginSuccess) {
      _lastSessionState = SessionState.authenticated;
      _pendingLogin = null;
      _pendingChallenge = null;
    }
    return mapped;
  }

  @override
  Future<StudentProfile> getProfile() async {
    _ensureOpen();
    if (provider is GraduateAcademicProvider) {
      return (provider as GraduateAcademicProvider).fetchProfile();
    }
    if (provider is UndergraduateAcademicProvider) {
      return (provider as UndergraduateAcademicProvider).fetchProfile();
    }
    throw const ProtocolChangedException(message: '当前 Provider 尚未开放学生资料解析');
  }

  @override
  Future<CourseFetchResult> getCourses(
      {required String year,
      required int semester,
      String? providerTermId}) async {
    _ensureOpen();
    if (!provider.capabilities.timetable) {
      throw const CourseNotOpenException(message: '当前 Provider 尚未开放课表');
    }
    final terms = await fetchTerms();
    final requested = providerTermId?.trim();
    AcademicTerm? term;
    if (requested != null && requested.isNotEmpty) {
      for (final candidate in terms) {
        if (candidate.providerTermId == requested) {
          term = candidate;
          break;
        }
      }
    }
    if (term == null && (requested == null || requested.isEmpty)) {
      final legacyRequested = '$year|${_legacySemesterCode(semester)}';
      for (final candidate in terms) {
        if (candidate.providerTermId == legacyRequested) {
          term = candidate;
          break;
        }
      }
    }
    if (term == null) {
      throw const AcademicFailure(
        kind: AcademicFailureKind.courseUnavailable,
        message: '学校学期列表中没有所选学期，请重新获取学期列表',
        code: 'ACADEMIC_TERM_NOT_FOUND',
      );
    }
    final schedule = await provider.fetchSchedule(term.providerTermId);
    // 研究生 Provider 的 periodOrder 是学校课表行序（从 0 开始），
    // periodLabel 是学校原标签；本科仍沿用 RawCourse 的数字节次契约。
    final preservesProviderPeriod =
        provider.id == AcademicProviderId.syluGraduate;
    return CourseFetchResult(
      courses: schedule.occurrences.map(
        (item) => RawCourse(
          name: item.courseName,
          teacher: item.teacher,
          location: item.location,
          section: item.periodLabel,
          // RawCourse 的旧桥接契约要求 1~7 数字星期；展示层再转换成
          // “周一”等文案，不能在仓储边界提前写入中文。
          weekDay: item.dayOfWeek.toString(),
          weekExpression: item.weekExpression,
          periodOrder: preservesProviderPeriod ? item.periodOrder : null,
          periodLabel: preservesProviderPeriod ? item.periodLabel : null,
        ),
      ),
      source: CourseSource.mobile,
    );
  }

  int _legacySemesterCode(int semester) {
    if (semester == 3) return 1;
    if (semester == 12) return 2;
    return semester;
  }

  @override
  Future<GradeFetchResult> getGrades(
      {required String year, required int semester}) async {
    _ensureOpen();
    if (!provider.capabilities.grades) {
      throw const GradeNotOpenException(message: '研究生成绩暂未开放，本版支持教务登录和课表');
    }
    if (provider is UndergraduateAcademicProvider) {
      return (provider as UndergraduateAcademicProvider)
          .fetchGrades(year: year, semester: semester);
    }
    throw const GradeNotOpenException(message: '当前 Provider 成绩适配器尚未接入');
  }

  @override
  Future<GradeDetail> getGradeDetail({
    required String year,
    required int semester,
    required String classId,
    required String courseName,
    String? courseId,
    String? studentGradeId,
  }) async {
    _ensureOpen();
    if (provider is UndergraduateAcademicProvider) {
      return (provider as UndergraduateAcademicProvider).fetchGradeDetail(
        year: year,
        semester: semester,
        classId: classId,
        courseName: courseName,
        courseId: courseId,
        studentGradeId: studentGradeId,
      );
    }
    throw const GradeNotOpenException(message: '当前 Provider 尚未开放成绩详情');
  }

  @override
  Future<AcademicSituation> getAcademicSituation() async {
    if (provider is UndergraduateAcademicProvider &&
        provider.capabilities.gpa) {
      return (provider as UndergraduateAcademicProvider)
          .fetchAcademicSituation();
    }
    throw const GradeNotOpenException(message: '当前 Provider 尚未开放 GPA 学业情况');
  }

  @override
  Future<CreditRequirement> getCreditRequirements() async {
    _ensureOpen();
    if (provider is UndergraduateAcademicProvider) {
      return (provider as UndergraduateAcademicProvider)
          .fetchCreditRequirements();
    }
    throw const GradeNotOpenException(message: '当前 Provider 尚未开放学分要求');
  }

  @override
  Future<void> resetSession() async {
    if (_closed) return;
    _pendingLogin = null;
    _pendingChallenge = null;
    _terms = null;
    _lastSessionState = SessionState.unauthenticated;
    await provider.clearSession();
  }

  @override
  Future<void> restoreSession() async {
    _ensureOpen();
    final state = await provider.probeSession();
    if (!state.authenticated) {
      _lastSessionState = SessionState.expired;
      throw const SessionExpiredException(message: '教务会话已失效');
    }
    if (state.confirmedStudentId != null &&
        state.confirmedStudentId != provider.identity.studentId) {
      _lastSessionState = SessionState.unauthenticated;
      throw const UnauthenticatedException(message: '学校返回的学生身份与当前绑定不一致');
    }
    _lastSessionState = SessionState.authenticated;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    provider.close();
  }

  Future<LoginResult> _mapLoginResult(AcademicLoginResult result) async =>
      switch (result) {
        AcademicLoginSucceeded(:final studentId) =>
          LoginSuccess(studentId: studentId, cookieNames: const <String>{}),
        AcademicLoginChallengeRequired(:final challenge) =>
          _saveChallenge(challenge),
        AcademicLoginRejected(:final error) => _mapAuthFailure(error),
      };

  LoginResult _saveChallenge(AcademicLoginChallenge challenge) {
    if (challenge is! ImageCaptchaChallenge) {
      return const LoginPageChanged(message: '当前教务 Provider 的登录挑战无法识别');
    }
    _pendingChallenge = challenge;
    return const CaptchaRequired(message: '请输入教务系统验证码');
  }

  LoginResult _mapAuthFailure(AcademicAuthFailure error) =>
      switch (error.type) {
        AcademicAuthFailureType.credentialMissing =>
          const LoginPageChanged(message: '请输入教务账号和密码'),
        AcademicAuthFailureType.credentialRejected =>
          InvalidCredentials(message: error.message),
        AcademicAuthFailureType.challengeRejected =>
          CaptchaExpired(message: error.message),
        AcademicAuthFailureType.sessionExpired =>
          CaptchaExpired(message: error.message),
        AcademicAuthFailureType.accountRejected ||
        AcademicAuthFailureType.accountRestricted ||
        AcademicAuthFailureType.authRejectedAmbiguous ||
        AcademicAuthFailureType.identityMismatch =>
          LoginPageChanged(message: error.message),
        AcademicAuthFailureType.challengeRequired =>
          CaptchaRequired(message: error.message),
      };

  void _ensureOpen() {
    if (_closed) throw StateError('ProviderAcademicRepository 已关闭');
  }
}
