import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

enum AcademicSourceKind { local, legacy }

/// 当前教务数据源明确提供的业务能力。
///
/// 能力是数据源契约的一部分。调用方必须在请求前依据能力决定是否展示或
/// 发起操作，不能等本机直连失败后再静默切回旧服务端代理。
final class AcademicCapabilities {
  const AcademicCapabilities({
    required this.supportsProfile,
    required this.supportsCourses,
    required this.supportsGrades,
    required this.supportsGradeDetail,
    required this.supportsAcademicSituation,
    required this.supportsCreditRequirements,
  });

  const AcademicCapabilities.local()
      : supportsProfile = true,
        supportsCourses = true,
        supportsGrades = true,
        supportsGradeDetail = false,
        supportsAcademicSituation = false,
        supportsCreditRequirements = false;

  const AcademicCapabilities.legacy()
      : supportsProfile = true,
        supportsCourses = true,
        supportsGrades = true,
        supportsGradeDetail = true,
        supportsAcademicSituation = true,
        supportsCreditRequirements = true;

  final bool supportsProfile;
  final bool supportsCourses;
  final bool supportsGrades;
  final bool supportsGradeDetail;
  final bool supportsAcademicSituation;
  final bool supportsCreditRequirements;
}

/// 主应用使用的教务仓储契约。
///
/// [switchSource] 是显式切换，不会在本地直连失败后偷偷改走旧代理，避免
/// 同一操作产生两套不同会话或把失败原因掩盖掉。
abstract interface class AcademicRepository {
  AcademicSourceKind get sourceKind;

  AcademicCapabilities get capabilities;

  SessionState get sessionState;

  String? get studentId;

  String get sourceName;

  Future<void> switchSource(AcademicSourceKind source);

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

  Future<void> resetSession();

  void close();
}
