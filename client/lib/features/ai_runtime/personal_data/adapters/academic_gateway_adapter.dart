import '../../../campus_data/storage/academic_cache_store.dart';
import '../../../campus_data/storage/personal_snapshot_models.dart';
import '../gateway/gateway_error.dart';
import '../gateway/gateway_result.dart';
import '../models/academic_overview.dart';

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
