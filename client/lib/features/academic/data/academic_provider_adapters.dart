import 'datasource/jiaowu_local_data_source.dart';
import 'package:dio/dio.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart' hide AcademicCapabilities;

import '../domain/academic_captcha_recognizer.dart';
import '../domain/academic_data_source.dart';
import '../domain/academic_provider.dart';
import 'graduate/graduate_protocol_client.dart';
import 'graduate/tflite_academic_captcha_recognizer.dart';

typedef GraduateGatewayFactory = GraduateProtocolGateway Function();
typedef GraduateCaptchaRecognizerFactory = AcademicCaptchaRecognizer Function();

/// 把已验证的研究生协议适配到统一 Academic Provider 边界。
final class GraduateAcademicProvider implements AcademicProvider {
  GraduateAcademicProvider({
    required AcademicIdentityKey identity,
    GraduateProtocolGateway? gateway,
    AcademicCaptchaRecognizer? captchaRecognizer,
  })  : _identity = identity,
        _gateway = gateway ?? GraduateProtocolClient(),
        _captchaRecognizer =
            captchaRecognizer ?? LazyTfliteAcademicCaptchaRecognizer();

  final AcademicIdentityKey _identity;
  final GraduateProtocolGateway _gateway;
  final AcademicCaptchaRecognizer _captchaRecognizer;
  ImageCaptchaChallenge? _pendingChallenge;
  AcademicCaptchaRecognition? _captchaSuggestion;
  bool _closed = false;

  @override
  AcademicIdentityKey get identity => _identity;

  @override
  AcademicProviderId get id => AcademicProviderId.syluGraduate;

  @override
  AcademicProviderCapabilities get capabilities => AcademicProviderCapabilities(
        timetable: true,
        captcha: true,
        localCaptchaRecognition: _captchaRecognizer.isAvailable,
      );

  /// 仅供 UI 显示为人工可核对建议，永远不会自动提交验证码。
  AcademicCaptchaRecognition? get captchaSuggestion => _captchaSuggestion;

  @override
  Future<AcademicLoginChallenge> prepareLogin() async {
    _ensureOpen();
    final captcha = await _gateway.prepareLogin();
    // 识别器失败或低置信度时保持空建议，现有 UI 继续要求人工输入。
    try {
      final recognition =
          await _captchaRecognizer.recognize(captcha.imageBytes);
      _captchaSuggestion =
          _captchaRecognizer.isAvailable && recognition.isManualSuggestion
              ? recognition
              : null;
    } catch (_) {
      _captchaSuggestion = null;
    }
    final challenge = ImageCaptchaChallenge(
      imageBytes: captcha.imageBytes,
      challengeId: captcha.challengeId ?? _identity.storageId,
      createdAt: DateTime.now().toUtc(),
      suggestedCode: _captchaSuggestion?.text,
      suggestionConfidence: _captchaSuggestion?.confidence,
    );
    _pendingChallenge = challenge;
    return challenge;
  }

  @override
  Future<AcademicLoginResult> login(AcademicLoginRequest request) async {
    _ensureOpen();
    try {
      final challenge = _pendingChallenge;
      if (request.captchaCode == null || request.captchaCode!.trim().isEmpty) {
        if (challenge == null) {
          final next = await prepareLogin();
          return AcademicLoginChallengeRequired(challenge: next);
        }
        return AcademicLoginChallengeRequired(challenge: challenge);
      }
      // 验证码是单次提交材料；无论学校返回哪类错误，都不能在下一次
      // 显式登录中复用旧图片和旧会话。
      _pendingChallenge = null;
      _captchaSuggestion = null;
      await _gateway.login(
        studentId: request.studentId.trim(),
        password: request.password,
        captchaCode: request.captchaCode!,
      );
      _pendingChallenge = null;
      _captchaSuggestion = null;
      return AcademicLoginSucceeded(studentId: request.studentId.trim());
    } on GraduatePortalException catch (error) {
      final type = _failureType(error.code);
      if (type == AcademicAuthFailureType.challengeRejected) {
        _pendingChallenge = null;
        _captchaSuggestion = null;
      }
      return AcademicLoginRejected(
        error:
            AcademicAuthFailure(type, error.message, providerCode: error.code),
      );
    } on DioException catch (error) {
      // 传输层错误交给既有白名单映射，保留超时、连接失败和 TLS 分类，
      // 不把 Dio 的请求对象、响应体或异常文本带入 UI。
      throw TransportErrorMapper.map(error, '研究生登录');
    } on FormatException catch (error) {
      // Codec/响应结构异常必须明确归为协议错误，避免被误显示为账号密码错误。
      throw ParseException(
        message: '研究生登录响应格式无法解析',
        code: 'GRADUATE_CODEC_FAILED',
        cause: error,
      );
    }
  }

  @override
  Future<void> restoreSession(ProviderSessionArtifact artifact) async {
    _ensureOpen();
    if (artifact.providerId != id ||
        artifact.studentId.trim() != _identity.studentId.trim()) {
      throw const AcademicAuthFailure(
          AcademicAuthFailureType.identityMismatch, '教务会话身份不匹配');
    }
    if (artifact.artifactVersion != graduateProtocolVersion ||
        DateTime.now().toUtc().difference(artifact.createdAt).isNegative ||
        DateTime.now().toUtc().difference(artifact.createdAt) > const Duration(hours: 12)) {
      throw const AcademicAuthFailure(
          AcademicAuthFailureType.sessionExpired, '教务会话材料已超过恢复期限');
    }
    final state = artifact.opaqueProviderState;
    final cookies = state['cookies'];
    final prefix = state['session_path_prefix'];
    if (cookies is! List || cookies.any((item) => item is! String) || prefix is! String) {
      throw const AcademicAuthFailure(
          AcademicAuthFailureType.sessionExpired, '教务会话材料格式无效');
    }
    await _gateway.restoreSession(
      GraduateSessionArtifactState(
        cookies: cookies.whereType<String>().toList(growable: false),
        sessionPathPrefix: prefix,
        // 恢复期限与探活时间以统一 Artifact 字段为准，避免两套时间戳漂移。
        createdAt: artifact.createdAt,
        validatedAt: artifact.validatedAt,
      ),
    );
    final confirmed = await _gateway.probe();
    if (!confirmed.authenticated) {
      throw const AcademicAuthFailure(AcademicAuthFailureType.sessionExpired, '研究生会话已失效');
    }
    if (confirmed.studentId?.trim() != _identity.studentId.trim()) {
      await _gateway.reset();
      throw const AcademicAuthFailure(AcademicAuthFailureType.identityMismatch, '研究生会话身份不匹配');
    }
  }

  @override
  Future<AcademicSessionProbeResult> probeSession() async {
    _ensureOpen();
    final state = await _gateway.probe();
    return AcademicSessionProbeResult(
      authenticated: state.authenticated,
      confirmedStudentId: state.studentId,
    );
  }

  Future<StudentProfile> fetchProfile() async {
    _ensureOpen();
    final profile = await _gateway.fetchProfile();
    final confirmed = profile.studentId?.trim() ?? '';
    if (confirmed.isEmpty || confirmed != _identity.studentId.trim()) {
      throw const AcademicAuthFailure(
        AcademicAuthFailureType.identityMismatch,
        '学校返回的学生身份与当前绑定不一致',
      );
    }
    return StudentProfile(
      name: profile.name ?? '',
      grade: '',
      college: '',
      major: '',
    );
  }

  @override
  Future<List<AcademicTerm>> fetchTerms() async {
    _ensureOpen();
    final terms = await _gateway.fetchTerms();
    return terms
        .map(
          (term) => AcademicTerm(
            providerId: id,
            providerTermId: term.code,
            displayName: term.name,
            isCurrent: term.selected,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<AcademicSchedule> fetchSchedule(String providerTermId) async {
    _ensureOpen();
    final schedule = await _gateway.fetchSchedule(providerTermId);
    final occurrences = <AcademicScheduleOccurrence>[];
    for (final slot in schedule.slots) {
      // 不合并同一单元格的课程，保证学校返回的多门课程全部进入领域层。
      for (final course in slot.courses) {
        occurrences.add(
          AcademicScheduleOccurrence(
            courseName: course.name,
            teacher: course.teacher,
            location: course.location,
            dayOfWeek: slot.dayOfWeek,
            periodOrder: slot.periodOrder,
            periodLabel: slot.periodLabel,
            weekExpression: course.weeks,
            providerMetadata: const <String, Object?>{
              'protocol_version': graduateProtocolVersion,
              'parser_version': graduateScheduleParserVersion,
            },
          ),
        );
      }
    }
    return AcademicSchedule(occurrences: occurrences);
  }

  @override
  Future<ProviderSessionArtifact?> exportSession() async {
    _ensureOpen();
    final state = await _gateway.exportSession();
    if (state == null) return null;
    return ProviderSessionArtifact(
      providerId: id,
      studentId: _identity.studentId,
      artifactVersion: graduateProtocolVersion,
      createdAt: state.createdAt,
      validatedAt: state.validatedAt,
      maxRestoreAge: const Duration(hours: 12),
      opaqueProviderState: <String, Object?>{
        'cookies': state.cookies,
        'session_path_prefix': state.sessionPathPrefix,
        'created_at': state.createdAt.toIso8601String(),
        'validated_at': state.validatedAt?.toIso8601String(),
      },
    );
  }

  @override
  Future<void> clearSession() async {
    if (_closed) return;
    _pendingChallenge = null;
    _captchaSuggestion = null;
    await _gateway.reset();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _captchaRecognizer.close();
    _gateway.close();
  }

  void _ensureOpen() {
    if (_closed) throw StateError('研究生教务 Provider 已关闭');
  }

  AcademicAuthFailureType _failureType(String code) => switch (code) {
        'CHALLENGE_REJECTED' ||
        'CAPTCHA_REJECTED' =>
          AcademicAuthFailureType.challengeRejected,
        'CREDENTIAL_REJECTED' => AcademicAuthFailureType.credentialRejected,
        'ACCOUNT_REJECTED' => AcademicAuthFailureType.accountRejected,
        'ACCOUNT_RESTRICTED' => AcademicAuthFailureType.accountRestricted,
        'SESSION_EXPIRED' => AcademicAuthFailureType.sessionExpired,
        'LOGIN_INPUT_INVALID' => AcademicAuthFailureType.credentialMissing,
        'LOGIN_PAGE_CHANGED' ||
        'PUBLIC_KEY_INVALID' =>
          AcademicAuthFailureType.authRejectedAmbiguous,
        _ => AcademicAuthFailureType.authRejectedAmbiguous,
      };
}

final class GraduateAcademicProviderFactory implements AcademicProviderFactory {
  GraduateAcademicProviderFactory({
    GraduateGatewayFactory? gatewayFactory,
    AcademicCaptchaRecognizer? captchaRecognizer,
    GraduateCaptchaRecognizerFactory? captchaRecognizerFactory,
  })  : _gatewayFactory = gatewayFactory,
        _captchaRecognizer = captchaRecognizer,
        _captchaRecognizerFactory = captchaRecognizerFactory;

  final GraduateGatewayFactory? _gatewayFactory;
  final AcademicCaptchaRecognizer? _captchaRecognizer;
  final GraduateCaptchaRecognizerFactory? _captchaRecognizerFactory;

  @override
  AcademicProviderId get id => AcademicProviderId.syluGraduate;

  @override
  AcademicProvider create(AcademicIdentityKey identity) =>
      GraduateAcademicProvider(
        identity: identity,
        gateway: _gatewayFactory?.call(),
        captchaRecognizer: _captchaRecognizerFactory?.call() ??
            _captchaRecognizer ??
            LazyTfliteAcademicCaptchaRecognizer(),
      );
}

/// 本科协议仍由既有 jiaowu_dart 数据源负责，适配器只做领域转换。
final class UndergraduateAcademicProvider implements AcademicProvider {
  UndergraduateAcademicProvider({
    required AcademicIdentityKey identity,
    required AcademicDataSource source,
  })  : _identity = identity,
        _source = source;

  final AcademicIdentityKey _identity;
  final AcademicDataSource _source;
  DateTime? _sessionCreatedAt;
  DateTime? _validatedAt;
  bool _closed = false;

  @override
  AcademicIdentityKey get identity => _identity;

  @override
  AcademicProviderId get id => AcademicProviderId.syluUndergraduate;

  @override
  AcademicProviderCapabilities get capabilities =>
      const AcademicProviderCapabilities(
        timetable: true,
        grades: true,
        exams: false,
        gpa: true,
        captcha: true,
      );

  @override
  Future<AcademicLoginChallenge> prepareLogin() async {
    _ensureOpen();
    // 本科登录是否需要验证码由学校响应决定，不能根据学号格式猜测。
    return const NoLoginChallenge();
  }

  @override
  Future<AcademicLoginResult> login(AcademicLoginRequest request) async {
    _ensureOpen();
    final result = await _source.login(
      studentId: request.studentId.trim(),
      password: request.password,
    );
    if (result is LoginSuccess) {
      return AcademicLoginSucceeded(studentId: result.studentId);
    }
    if (result is CaptchaRequired) {
      final captcha = await _source.getCaptchaChallenge();
      return AcademicLoginChallengeRequired(
        challenge: ImageCaptchaChallenge(
          imageBytes: captcha.imageBytes,
          challengeId: _identity.storageId,
          createdAt: DateTime.now().toUtc(),
        ),
      );
    }
    if (result is CaptchaExpired) {
      return const AcademicLoginRejected(
        error: AcademicAuthFailure(
          AcademicAuthFailureType.challengeRejected,
          '验证码会话已失效，请重新获取验证码',
        ),
      );
    }
    if (result is InvalidCredentials) {
      return AcademicLoginRejected(
        error: AcademicAuthFailure(
          AcademicAuthFailureType.credentialRejected,
          result.message,
        ),
      );
    }
    return AcademicLoginRejected(
      error: AcademicAuthFailure(
        AcademicAuthFailureType.authRejectedAmbiguous,
        result is NetworkUnavailable ? result.message : '本科教务登录失败',
      ),
    );
  }

  @override
  Future<void> restoreSession(ProviderSessionArtifact artifact) async {
    _ensureOpen();
    if (artifact.providerId != id ||
        artifact.studentId.trim() != _identity.studentId.trim()) {
      throw const AcademicAuthFailure(
          AcademicAuthFailureType.identityMismatch, '教务会话身份不匹配');
    }
    if (artifact.artifactVersion != 1 ||
        DateTime.now().toUtc().difference(artifact.createdAt).isNegative ||
        DateTime.now().toUtc().difference(artifact.createdAt) > const Duration(hours: 8)) {
      throw const AcademicAuthFailure(AcademicAuthFailureType.sessionExpired, '本科会话材料已超龄');
    }
    final source = _source;
    final cookies = artifact.opaqueProviderState['cookies'];
    if (source is! JiaowuLocalDataSource || cookies is! List || cookies.any((item) => item is! String)) {
      throw const AcademicAuthFailure(AcademicAuthFailureType.sessionExpired, '本科会话材料无效');
    }
    try {
      await source.importCookies(cookies.cast<String>(), _identity.studentId);
    } on FormatException {
      throw const AcademicAuthFailure(AcademicAuthFailureType.sessionExpired, '本科会话材料损坏');
    }
    _sessionCreatedAt = artifact.createdAt;
    final state = await probeSession();
    if (!state.authenticated) {
      throw const AcademicAuthFailure(AcademicAuthFailureType.sessionExpired, '本科教务会话已失效');
    }
  }

  @override
  Future<AcademicSessionProbeResult> probeSession() async {
    final source = _source;
    if (source is JiaowuLocalDataSource) {
      final profile = await source.probeSession();
      _validatedAt = DateTime.now().toUtc();
      return AcademicSessionProbeResult(authenticated: true, confirmedStudentId: profile.studentId);
    }
    return AcademicSessionProbeResult(
      authenticated: source.sessionState == SessionState.authenticated,
      confirmedStudentId: source.studentId);
  }

  Future<StudentProfile> fetchProfile() async {
    _ensureOpen();
    final profile = await _source.getProfile();
    final confirmedStudentId = profile.studentId?.trim() ?? '';
    if (confirmedStudentId.isEmpty ||
        confirmedStudentId != _identity.studentId.trim()) {
      throw const AcademicAuthFailure(
        AcademicAuthFailureType.identityMismatch,
        '学校资料页未确认当前本科教务学号',
      );
    }
    _validatedAt = DateTime.now().toUtc();
    return profile;
  }

  /// 本科协议已经由底层 POC 提供成绩和学业情况解析，桥接层只暴露
  /// 这些真实存在的调用，不在 Provider 内重新推导成绩或 GPA。
  Future<GradeFetchResult> fetchGrades({
    required String year,
    required int semester,
  }) async {
    _ensureOpen();
    return _source.getGrades(year: year, semester: semester);
  }

  Future<AcademicSituation> fetchAcademicSituation() async {
    _ensureOpen();
    return _source.getAcademicSituation();
  }

  Future<CreditRequirement> fetchCreditRequirements() async {
    _ensureOpen();
    return _source.getCreditRequirements();
  }

  @override
  Future<List<AcademicTerm>> fetchTerms() async {
    _ensureOpen();
    final now = DateTime.now();
    final currentYear = now.month >= 8 ? now.year : now.year - 1;
    final currentSemester = now.month >= 2 && now.month <= 7 ? 12 : 3;
    final enrollmentYear = _inferredEnrollmentYear;
    final endYear = now.year + 1;
    final terms = <AcademicTerm>[];
    for (var year = enrollmentYear; year <= endYear; year++) {
      for (final semester in const <int>[3, 12]) {
        terms.add(
          AcademicTerm(
            providerId: id,
            // jiaowu_dart 的课表契约使用 3/12，不能把成绩接口的 1/2
            // 学期码直接复用到课表请求。
            providerTermId: '$year|$semester',
            displayName: '$year-${year + 1}${semester == 3 ? '第一' : '第二'}学期',
            isCurrent: year == currentYear && semester == currentSemester,
            localYear: '$year',
            localSemester: semester,
          ),
        );
      }
    }
    terms.sort((a, b) {
      final yearCompare = (b.localYear ?? '').compareTo(a.localYear ?? '');
      if (yearCompare != 0) return yearCompare;
      return (b.localSemester ?? 0).compareTo(a.localSemester ?? 0);
    });
    return terms;
  }

  @override
  Future<AcademicSchedule> fetchSchedule(String providerTermId) async {
    _ensureOpen();
    final parts = providerTermId.split('|');
    final semester = int.tryParse(parts.length == 2 ? parts[1] : '');
    if (parts.length != 2 || semester == null || !{3, 12}.contains(semester)) {
      throw const FormatException('本科 Provider 学期标识格式无效');
    }
    final raw = await _source.getCourses(year: parts[0], semester: semester);
    return AcademicSchedule(
      occurrences: raw.courses.map(
        (course) => AcademicScheduleOccurrence(
          courseName: course.name,
          teacher: course.teacher,
          location: course.location,
          dayOfWeek: _weekday(course.weekDay),
          periodOrder:
              int.tryParse(RegExp(r'\d+').stringMatch(course.section) ?? '') ??
                  0,
          periodLabel: course.section,
          weekExpression: course.weekExpression,
        ),
      ),
    );
  }

  @override
  Future<ProviderSessionArtifact?> exportSession() async {
    final source = _source;
    if (source is! JiaowuLocalDataSource || source.sessionState != SessionState.authenticated) return null;
    _sessionCreatedAt ??= DateTime.now().toUtc();
    return ProviderSessionArtifact(providerId: id, studentId: _identity.studentId,
      artifactVersion: 1, createdAt: _sessionCreatedAt!, validatedAt: _validatedAt,
      maxRestoreAge: const Duration(hours: 8),
      opaqueProviderState: {'cookies': await source.exportCookies()});
  }

  @override
  Future<void> clearSession() async {
    _sessionCreatedAt = null;
    _validatedAt = null;
    await _source.resetSession();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _source.close();
  }

  int _weekday(String value) {
    final normalized = value.trim();
    final digit = int.tryParse(RegExp(r'\d+').stringMatch(normalized) ?? '');
    if (digit != null && digit >= 1 && digit <= 7) return digit;
    const names = <String, int>{
      '一': 1,
      '二': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '日': 7,
      '天': 7
    };
    return names.entries
        .firstWhere((entry) => normalized.contains(entry.key),
            orElse: () => const MapEntry('', 0))
        .value;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('本科教务 Provider 已关闭');
  }

  int get _inferredEnrollmentYear {
    final studentId = _identity.studentId.trim();
    if (studentId.length >= 2) {
      final prefix = int.tryParse(studentId.substring(0, 2));
      if (prefix != null && prefix > 0 && prefix < 99) return 2000 + prefix;
    }
    return DateTime.now().year - 4;
  }
}

final class UndergraduateAcademicProviderFactory
    implements AcademicProviderFactory {
  UndergraduateAcademicProviderFactory({required this.sourceFactory});

  final AcademicDataSource Function(AcademicIdentityKey identity) sourceFactory;

  @override
  AcademicProviderId get id => AcademicProviderId.syluUndergraduate;

  @override
  AcademicProvider create(AcademicIdentityKey identity) =>
      UndergraduateAcademicProvider(
          identity: identity, source: sourceFactory(identity));
}
