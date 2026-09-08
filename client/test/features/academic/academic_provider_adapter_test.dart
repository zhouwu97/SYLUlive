import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/data/academic_provider_adapters.dart';
import 'package:shenliyuan/features/academic/data/academic_provider_router_repository.dart';
import 'package:shenliyuan/features/academic/data/academic_repository_impl.dart';
import 'package:shenliyuan/features/academic/data/graduate/tflite_academic_captcha_recognizer.dart';
import 'package:shenliyuan/features/academic/data/provider_academic_repository.dart';
import 'package:shenliyuan/features/academic/domain/academic_captcha_recognizer.dart';
import 'package:shenliyuan/features/academic/domain/academic_data_source.dart';
import 'package:shenliyuan/features/academic/domain/academic_failure.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/academic/domain/academic_repository.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/account_session_cleanup_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppPreferencesStore.setMockInitialValues({});

  test('验证码候选阈值只用于人工核对，低置信和无效结果不显示', () async {
    const manual = ManualAcademicCaptchaRecognizer();
    final result = await manual.recognize(Uint8List.fromList(<int>[1]));

    expect(manual.isAvailable, isFalse);
    expect(result.isManualSuggestion, isFalse);
    expect(
      const AcademicCaptchaRecognition(text: '1234', confidence: 0.69)
          .isManualSuggestion,
      isFalse,
    );
    expect(
      const AcademicCaptchaRecognition(text: '1234', confidence: 0.70)
          .isManualSuggestion,
      isTrue,
    );
    expect(
      const AcademicCaptchaRecognition(text: '123', confidence: 0.99)
          .isManualSuggestion,
      isFalse,
    );
    expect(
      AcademicCaptchaRecognition(text: '1234', confidence: double.nan)
          .isManualSuggestion,
      isFalse,
    );
    expect(
      AcademicCaptchaRecognition(text: '1234', confidence: double.infinity)
          .isManualSuggestion,
      isFalse,
    );
  });

  test('TFLite 模型加载失败时保留人工验证码流程', () async {
    final recognizer = LazyTfliteAcademicCaptchaRecognizer(
      loader: () async => throw StateError('model fixture unavailable'),
    );

    final result = await recognizer.recognize(Uint8List.fromList(<int>[1, 2]));

    expect(result.text, isEmpty);
    expect(result.confidence, 0);
    recognizer.close();
  });

  test('本科 Provider 桥接真实委托成绩和 GPA，不返回未接入占位错误', () async {
    final source = _RecordingAcademicDataSource();
    final provider = UndergraduateAcademicProvider(
      identity: const AcademicIdentityKey(
        appUserId: 'app-user',
        providerId: AcademicProviderId.syluUndergraduate,
        studentId: 'U-001',
      ),
      source: source,
    );
    final repository = ProviderAcademicRepository(provider);

    final grades = await repository.getGrades(year: '2025', semester: 1);
    final situation = await repository.getAcademicSituation();

    expect(grades.pages, 1);
    expect(situation.allGpa, 3.8);
    expect(source.gradesCalls, 1);
    expect(source.situationCalls, 1);

    repository.close();
  });

  test('本科资料页缺少或返回错误学号时拒绝通过 Match Gate', () async {
    final source = _RecordingAcademicDataSource(profileStudentId: 'U-002');
    final provider = UndergraduateAcademicProvider(
      identity: const AcademicIdentityKey(
        appUserId: 'app-user',
        providerId: AcademicProviderId.syluUndergraduate,
        studentId: 'U-001',
      ),
      source: source,
    );

    await expectLater(
      provider.fetchProfile(),
      throwsA(
        isA<AcademicAuthFailure>().having(
          (error) => error.type,
          'type',
          AcademicAuthFailureType.identityMismatch,
        ),
      ),
    );
    provider.close();
  });

  test('显式 providerTermId 未命中时不回退其他学期且不拉取课表', () async {
    final provider = _TermRecordingProvider();
    final repository = ProviderAcademicRepository(provider);

    await expectLater(
      repository.getCourses(
        year: '2026',
        semester: 3,
        providerTermId: 'term-not-found',
      ),
      throwsA(
        isA<AcademicFailure>().having(
          (error) => error.code,
          'code',
          'ACADEMIC_TERM_NOT_FOUND',
        ),
      ),
    );
    expect(provider.scheduleCalls, 0);
    repository.close();
  });

  test('Provider 仓储输出数字星期，兼容旧课表映射边界', () async {
    final provider = _TermRecordingProvider(emitCourse: true);
    final repository = ProviderAcademicRepository(provider);

    final result = await repository.getCourses(
      year: '2026',
      semester: 3,
      providerTermId: 'term-current',
    );

    expect(result.courses.single.weekDay, '1');
    repository.close();
  });

  test('Provider 到 EduProvider 的课表映射保留星期、节次和周次', () async {
    final provider = _TermRecordingProvider(emitCourse: true);
    final controller = AcademicSessionController.forProvider(
      provider: provider,
      identity: provider.identity,
      cleanupCoordinator: AccountSessionCleanupCoordinator(),
    );
    final edu = EduProvider(Dio())..setAcademicSessionController(controller);
    addTearDown(() {
      edu.dispose();
      controller.dispose();
    });

    await controller.syncAppUser('app-user');
    await controller.allowDeviceConnection();
    final login = await controller.login(
      studentId: provider.identity.studentId,
      password: 'fixture-password',
    );
    expect(login, isA<LoginSuccess>());
    edu.setUserId('app-user');
    await edu.ensureStatusLoaded();

    final result = await edu.getCourses(
      '2026',
      3,
      providerTermId: 'term-current',
    );

    expect(result?.success, isTrue);
    final course = result?.data?.single;
    expect(course?['weekday'], 1);
    expect(course?['start_section'], 2);
    expect(course?['end_section'], 2);
    expect(course?['period_order'], 1);
    expect(course?['period_label'], '上午第1-2节');
    expect(course?['weeks'],
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]);
  });

  test('研究生 Provider 透传真实节次标签而不按标签数字推断本科节次', () async {
    final provider = _TermRecordingProvider(
      emitCourse: true,
      periodOrder: 2,
      periodLabel: '上午3',
    );
    final repository = ProviderAcademicRepository(provider);
    final controller = AcademicSessionController.forProvider(
      provider: provider,
      identity: provider.identity,
      cleanupCoordinator: AccountSessionCleanupCoordinator(),
    );
    final edu = EduProvider(Dio())..setAcademicSessionController(controller);
    addTearDown(() {
      edu.dispose();
      controller.dispose();
    });

    await controller.syncAppUser('app-user');
    await controller.allowDeviceConnection();
    await controller.login(
      studentId: provider.identity.studentId,
      password: 'fixture-password',
    );
    edu.setUserId('app-user');
    await edu.ensureStatusLoaded();

    final raw = await repository.getCourses(
      year: '2026',
      semester: 3,
      providerTermId: 'term-current',
    );
    expect(raw.courses.single.section, '上午3');
    expect(raw.courses.single.periodOrder, 2);
    expect(raw.courses.single.periodLabel, '上午3');

    final result = await edu.getCourses(
      '2026',
      3,
      providerTermId: 'term-current',
    );
    expect(result?.success, isTrue);
    expect(result?.data?.single['start_section'], 3);
    expect(result?.data?.single['end_section'], 3);
    expect(result?.data?.single['period_order'], 2);
    expect(result?.data?.single['period_label'], '上午3');
    repository.close();
  });

  test('本科课表学期保留历史范围并向 POC 传递 3/12 学期码', () async {
    final source = _RecordingAcademicDataSource();
    final provider = UndergraduateAcademicProvider(
      identity: const AcademicIdentityKey(
        appUserId: 'app-user',
        providerId: AcademicProviderId.syluUndergraduate,
        studentId: '2403060128',
      ),
      source: source,
    );
    final now = DateTime.now();
    final currentYear = now.month >= 8 ? now.year : now.year - 1;

    final terms = await provider.fetchTerms();

    expect(
      terms.any((term) => term.providerTermId == '$currentYear|3'),
      isTrue,
    );
    expect(
      terms.any((term) => term.providerTermId == '2024|12'),
      isTrue,
    );
    await provider.fetchSchedule('$currentYear|3');
    expect(source.lastCourseYear, '$currentYear');
    expect(source.lastCourseSemester, 3);

    await provider.fetchSchedule('${currentYear - 1}|12');
    expect(source.lastCourseYear, '${currentYear - 1}');
    expect(source.lastCourseSemester, 12);
    provider.close();
  });

  test('Router 学期读取转发到已选本机 Provider', () async {
    final legacySource = _RecordingAcademicDataSource();
    final legacy = AcademicRepositoryImpl(
      local: legacySource,
      legacy: legacySource,
      source: AcademicSourceKind.legacy,
    );
    final router = AcademicProviderRouterRepository(
      legacy: legacy,
      registry: AcademicProviderRegistry([
        UndergraduateAcademicProviderFactory(
          sourceFactory: (_) => _RecordingAcademicDataSource(),
        ),
      ]),
    );
    router.syncAppUser('app-user');
    await router.selectProvider(
      const AcademicIdentityKey(
        appUserId: 'app-user',
        providerId: AcademicProviderId.syluUndergraduate,
        studentId: '2403060128',
      ),
    );

    final terms = await router.fetchTerms();

    expect(terms, isNotEmpty);
    expect(terms.any((term) => term.providerTermId.endsWith('|3')), isTrue);
    router.close();
  });
}

final class _TermRecordingProvider implements AcademicProvider {
  _TermRecordingProvider({
    this.emitCourse = false,
    this.periodLabel = '上午第1-2节',
    this.periodOrder = 1,
  });

  final bool emitCourse;
  final String periodLabel;
  final int periodOrder;

  final AcademicIdentityKey identity = const AcademicIdentityKey(
    appUserId: 'app-user',
    providerId: AcademicProviderId.syluGraduate,
    studentId: 'G-001',
  );
  int scheduleCalls = 0;

  @override
  AcademicProviderId get id => identity.providerId;

  @override
  AcademicProviderCapabilities get capabilities =>
      const AcademicProviderCapabilities(timetable: true);

  @override
  Future<AcademicLoginChallenge> prepareLogin() async =>
      const NoLoginChallenge();

  @override
  Future<AcademicLoginResult> login(AcademicLoginRequest request) async =>
      AcademicLoginSucceeded(studentId: request.studentId);

  @override
  Future<void> restoreSession(ProviderSessionArtifact artifact) async {}

  @override
  Future<AcademicSessionProbeResult> probeSession() async =>
      const AcademicSessionProbeResult(authenticated: true);

  @override
  Future<List<AcademicTerm>> fetchTerms() async => const <AcademicTerm>[
        AcademicTerm(
          providerId: AcademicProviderId.syluGraduate,
          providerTermId: 'term-current',
          displayName: '学校当前学期',
          isCurrent: true,
        ),
      ];

  @override
  Future<AcademicSchedule> fetchSchedule(String providerTermId) async {
    scheduleCalls++;
    return AcademicSchedule(
      occurrences: emitCourse
          ? <AcademicScheduleOccurrence>[
              AcademicScheduleOccurrence(
                courseName: '测试课程',
                teacher: '测试教师',
                location: '测试教室',
                dayOfWeek: 1,
                periodOrder: periodOrder,
                periodLabel: periodLabel,
                weekExpression: '1-16周',
              ),
            ]
          : const <AcademicScheduleOccurrence>[],
    );
  }

  @override
  Future<ProviderSessionArtifact?> exportSession() async => null;

  @override
  Future<void> clearSession() async {}

  @override
  void close() {}
}

final class _RecordingAcademicDataSource implements AcademicDataSource {
  _RecordingAcademicDataSource({this.profileStudentId});

  final String? profileStudentId;
  int gradesCalls = 0;
  int situationCalls = 0;
  String? lastCourseYear;
  int? lastCourseSemester;

  @override
  String get sourceName => 'fixture';

  @override
  SessionState get sessionState => SessionState.authenticated;

  @override
  String get studentId => 'U-001';

  @override
  Future<LoginResult> login({
    required String studentId,
    required String password,
  }) async =>
      const LoginSuccess(studentId: 'U-001', cookieNames: <String>{});

  @override
  Future<CaptchaChallenge> getCaptchaChallenge() async =>
      CaptchaChallenge(imageBytes: Uint8List.fromList(<int>[1]));

  @override
  Future<LoginResult> continueLoginWithCaptcha({required String code}) async =>
      const LoginSuccess(studentId: 'U-001', cookieNames: <String>{});

  @override
  Future<StudentProfile> getProfile() async => StudentProfile(
        name: 'fixture',
        grade: '2025',
        college: 'fixture',
        major: 'fixture',
        studentId: profileStudentId,
      );

  @override
  Future<CourseFetchResult> getCourses({
    required String year,
    required int semester,
  }) async {
    lastCourseYear = year;
    lastCourseSemester = semester;
    return CourseFetchResult(
      courses: const <RawCourse>[],
      source: CourseSource.mobile,
    );
  }

  @override
  Future<GradeFetchResult> getGrades({
    required String year,
    required int semester,
  }) async {
    gradesCalls++;
    return GradeFetchResult(grades: const <RawGrade>[], pages: 1);
  }

  @override
  Future<GradeDetail> getGradeDetail({
    required String year,
    required int semester,
    required String classId,
    required String courseName,
    String? courseId,
    String? studentGradeId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<AcademicSituation> getAcademicSituation() async {
    situationCalls++;
    return const AcademicSituation(
      success: true,
      allGpa: 3.8,
      degreeGpa: null,
      totalCourses: 0,
      passedCourses: 0,
      failedCourses: 0,
      notStartedCourses: 0,
      inProgressCourses: 0,
      degreeTotalCourses: 0,
      degreePassedCourses: 0,
      degreeFailedCourses: 0,
      degreeNotStartedCourses: 0,
      degreeInProgressCourses: 0,
      courses: <AcademicCourse>[],
      coursesStatus: 'loaded',
    );
  }

  @override
  Future<CreditRequirement> getCreditRequirements() async =>
      const CreditRequirement(
        success: true,
        status: 'loaded',
        modules: <CreditModule>[],
        improvementCourses: <ImprovementCourse>[],
      );

  @override
  Future<void> resetSession() async {}

  @override
  Future<void> restoreSession() async {}

  @override
  void close() {}
}
