import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

/// 教务数据源的最小能力边界。
///
/// 本接口只描述一次运行时会话需要的能力，不暴露 Dio、CookieJar 或原始
/// 响应。这样本地直连和旧服务端代理可以被仓储互换，而不会把两套认证
/// 会话混在一起。
abstract interface class AcademicDataSource {
  String get sourceName;

  SessionState get sessionState;

  String? get studentId;

  Future<LoginResult> login({
    required String studentId,
    required String password,
  });

  Future<CaptchaChallenge> getCaptchaChallenge();

  Future<LoginResult> continueLoginWithCaptcha({required String code});

  Future<StudentProfile> getProfile();

  Future<CourseFetchResult> getCourses({
    required String year,
    required int semester,
  });

  Future<GradeFetchResult> getGrades({
    required String year,
    required int semester,
  });

  Future<GradeDetail> getGradeDetail({
    required String year,
    required int semester,
    required String classId,
    required String courseName,
    String? courseId,
    String? studentGradeId,
  });

  Future<AcademicSituation> getAcademicSituation();

  Future<CreditRequirement> getCreditRequirements();

  Future<void> resetSession();

  void close();
}
