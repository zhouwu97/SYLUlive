import '../../../campus_data/storage/academic_cache_store.dart';
import '../../../campus_data/storage/personal_snapshot_models.dart';
import '../gateway/gateway_error.dart';
import '../gateway/gateway_result.dart';
import '../models/academic_overview.dart';
import '../models/academic_records.dart';

/// 将已认证的加密成绩限制为学期覆盖和数量信息。
class AcademicGatewayAdapter {
  AcademicGatewayAdapter({required AcademicCacheStore cacheStore})
      : _cacheStore = cacheStore;

  final AcademicCacheStore _cacheStore;

  Future<GatewayResult<AcademicOverview>> loadOverview() async {
    try {
      final snapshot = await _cacheStore.readSnapshot();
      if (snapshot == null) {
        return GatewayResult<AcademicOverview>(
          status: GatewayStatus.missing,
          source: PersonalDataSource.none,
        );
      }

      final terms = snapshot.terms.values
          .map(
            (term) => AcademicTermOverview(
              year: term.year,
              semester: term.semester,
              courseCount: term.grades.length,
              fetchedAt: term.fetchedAt,
            ),
          )
          .toList()
        ..sort(_compareTerms);
      final totalRecordedCourses = terms.fold<int>(
        0,
        (total, term) => total + term.courseCount,
      );
      final situation = snapshot.situation;
      return GatewayResult<AcademicOverview>(
        data: AcademicOverview(
          terms: terms,
          totalRecordedCourses: totalRecordedCourses,
          hasAcademicSituation: situation != null,
          academicSituationFetchedAt: situation?.fetchedAt,
        ),
        status:
            snapshot.isStale ? GatewayStatus.stale : GatewayStatus.available,
        source: PersonalDataSource.localEncryptedVault,
        fetchedAt: snapshot.fetchedAt,
        expiresAt: snapshot.expiresAt,
        isStale: snapshot.isStale,
        warnings: snapshot.isStale
            ? const <String>['成绩数据已过期，建议先同步']
            : const <String>[],
      );
    } on PersonalSnapshotStoreException {
      return _corruptedResult();
    } on FormatException {
      return _corruptedResult();
    } catch (_) {
      return _corruptedResult();
    }
  }

  Future<GatewayResult<AcademicRecords>> loadRecords() async {
    try {
      final snapshot = await _cacheStore.readSnapshot();
      if (snapshot == null) {
        return GatewayResult<AcademicRecords>(
          status: GatewayStatus.missing,
          source: PersonalDataSource.none,
        );
      }
      final records = <CourseGradeRecord>[];
      for (final term in snapshot.terms.values) {
        for (var index = 0; index < term.grades.length; index++) {
          final raw = term.grades[index];
          final name =
              (raw['name'] ?? raw['course_name'] ?? '').toString().trim();
          final id =
              (raw['course_id'] ?? raw['course_code'] ?? '').toString().trim();
          records.add(
            CourseGradeRecord(
              courseId: id.isEmpty ? '${term.termId}:$index:$name' : id,
              courseName: name,
              score: _double(raw['fraction']) ?? _double(raw['score']),
              gradeText: (raw['grade'] ?? raw['effective_grade'])?.toString(),
              credit: _double(raw['credits']) ?? 0,
              nature: _nature(raw['course_nature'] ?? raw['course_category']),
              attemptType: _attempt(raw['exam_type'] ?? raw['course_category']),
              semesterId: term.termId,
            ),
          );
        }
      }
      return GatewayResult<AcademicRecords>(
        data: AcademicRecords(courses: records),
        status:
            snapshot.isStale ? GatewayStatus.stale : GatewayStatus.available,
        source: PersonalDataSource.localEncryptedVault,
        fetchedAt: snapshot.fetchedAt,
        expiresAt: snapshot.expiresAt,
        isStale: snapshot.isStale,
        warnings: snapshot.isStale
            ? const <String>['成绩数据已过期，建议先同步']
            : const <String>[],
      );
    } catch (_) {
      return GatewayResult<AcademicRecords>(
        status: GatewayStatus.corrupted,
        source: PersonalDataSource.none,
        warnings: const <String>['成绩本地加密数据无法验证，请重新同步'],
        error: const GatewayError(GatewayErrorCode.corrupted, '成绩本地数据不可用'),
      );
    }
  }

  static double? _double(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  static CourseNature _nature(Object? value) {
    final text = value?.toString() ?? '';
    if (text.contains('必修')) return CourseNature.requiredCourse;
    if (text.contains('选修')) return CourseNature.elective;
    return CourseNature.other;
  }

  static CourseAttemptType _attempt(Object? value) {
    final text = value?.toString() ?? '';
    if (text.contains('重修')) return CourseAttemptType.retake;
    if (text.contains('补考')) return CourseAttemptType.makeup;
    return CourseAttemptType.normal;
  }

  GatewayResult<AcademicOverview> _corruptedResult() {
    return GatewayResult<AcademicOverview>(
      status: GatewayStatus.corrupted,
      source: PersonalDataSource.none,
      warnings: const <String>['成绩本地加密数据无法验证，请重新同步'],
      error: const GatewayError(GatewayErrorCode.corrupted, '成绩本地数据不可用'),
    );
  }

  static int _compareTerms(
    AcademicTermOverview left,
    AcademicTermOverview right,
  ) {
    final year = right.year.compareTo(left.year);
    if (year != 0) return year;
    return right.semester.compareTo(left.semester);
  }
}
