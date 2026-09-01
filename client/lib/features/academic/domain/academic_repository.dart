import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

enum AcademicSourceKind { local, legacy }

/// 主应用使用的教务仓储契约。
///
/// [switchSource] 是显式切换，不会在本地直连失败后偷偷改走旧代理，避免
/// 同一操作产生两套不同会话或把失败原因掩盖掉。
abstract interface class AcademicRepository {
  AcademicSourceKind get sourceKind;

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
