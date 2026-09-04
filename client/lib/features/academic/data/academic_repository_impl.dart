import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

import '../domain/academic_data_source.dart';
import '../domain/academic_failure.dart';
import '../domain/academic_repository.dart';

/// [AcademicDataSource] 的异常边界实现。
final class AcademicRepositoryImpl implements AcademicRepository {
  AcademicRepositoryImpl({
    required AcademicDataSource local,
    required AcademicDataSource legacy,
    AcademicSourceKind source = AcademicSourceKind.local,
  })  : _local = local,
        _legacy = legacy,
        _source = source;

  final AcademicDataSource _local;
  final AcademicDataSource _legacy;
  AcademicSourceKind _source;
  bool _closed = false;

  AcademicDataSource get _active => switch (_source) {
        AcademicSourceKind.local => _local,
        AcademicSourceKind.legacy => _legacy,
      };

  @override
  AcademicSourceKind get sourceKind => _source;

  @override
  AcademicCapabilities get capabilities => switch (_source) {
        AcademicSourceKind.local => const AcademicCapabilities.local(),
        AcademicSourceKind.legacy => const AcademicCapabilities.legacy(),
      };

  @override
  SessionState get sessionState => _active.sessionState;

  @override
  String? get studentId => _active.studentId;

  @override
  String get sourceName => _active.sourceName;

  @override
  Future<void> switchSource(AcademicSourceKind source) async {
    _ensureOpen();
    if (_source == source) return;
    try {
      await _active.resetSession();
      _source = source;
    } catch (error) {
      throw AcademicFailure.fromException(error);
    }
  }

  @override
  Future<LoginResult> login({
    required String studentId,
    required String password,
  }) {
    return _guard(() => _active.login(
          studentId: studentId,
          password: password,
        ));
  }

  @override
  Future<CaptchaChallenge> getCaptchaChallenge() {
    return _guard(_active.getCaptchaChallenge);
  }

  @override
  Future<LoginResult> continueLoginWithCaptcha({required String code}) {
    return _guard(() => _active.continueLoginWithCaptcha(code: code));
  }

  @override
  Future<StudentProfile> getProfile() => _guard(_active.getProfile);

  @override
  Future<CourseFetchResult> getCourses({
    required String year,
    required int semester,
  }) {
    return _guard(() => _active.getCourses(year: year, semester: semester));
  }

  @override
  Future<GradeFetchResult> getGrades({
    required String year,
    required int semester,
  }) {
    return _guard(() => _active.getGrades(year: year, semester: semester));
  }

  @override
  Future<GradeDetail> getGradeDetail({
    required String year,
    required int semester,
    required String classId,
    required String courseName,
    String? courseId,
    String? studentGradeId,
  }) {
    return _guard(() => _active.getGradeDetail(
          year: year,
          semester: semester,
          classId: classId,
          courseName: courseName,
          courseId: courseId,
          studentGradeId: studentGradeId,
        ));
  }

  @override
  Future<AcademicSituation> getAcademicSituation() =>
      _guard(_active.getAcademicSituation);

  @override
  Future<CreditRequirement> getCreditRequirements() =>
      _guard(_active.getCreditRequirements);

  @override
  Future<void> resetSession() async {
    _ensureOpen();
    try {
      await _active.resetSession();
    } catch (error) {
      throw AcademicFailure.fromException(error);
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _local.close();
    _legacy.close();
  }

  Future<T> _guard<T>(Future<T> Function() operation) async {
    _ensureOpen();
    try {
      return await operation();
    } catch (error) {
      throw AcademicFailure.fromException(error);
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('AcademicRepository 已关闭');
  }
}
