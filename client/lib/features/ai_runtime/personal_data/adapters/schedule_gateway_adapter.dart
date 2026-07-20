import '../../../campus_data/storage/personal_snapshot_models.dart';
import '../../../campus_data/storage/schedule_cache_store.dart';
import '../gateway/gateway_error.dart';
import '../gateway/gateway_result.dart';
import '../models/schedule_overview.dart';

/// 将已认证的加密课表限制为指定日期范围内的最小化出现项。
class ScheduleGatewayAdapter {
  ScheduleGatewayAdapter({
    required ScheduleCacheStore cacheStore,
    Future<bool> Function()? needsResync,
  })  : _cacheStore = cacheStore,
        _needsResync = needsResync;

  static const int _maxRangeDays = 31;
  static const Duration _lastTermMaximumDuration = Duration(days: 26 * 7);

  final ScheduleCacheStore _cacheStore;
  final Future<bool> Function()? _needsResync;

  Future<GatewayResult<ScheduleOverview>> loadOverview({
    required DateTime start,
    required DateTime end,
  }) async {
    final normalizedStart = _utcDate(start);
    final normalizedEnd = _utcDate(end);
    final rangeDays = normalizedEnd.difference(normalizedStart).inDays;
    if (rangeDays < 0 || rangeDays >= _maxRangeDays) {
      return GatewayResult<ScheduleOverview>(
        status: GatewayStatus.unsupported,
        source: PersonalDataSource.none,
        warnings: const <String>['课表读取范围必须在 31 天以内'],
        error: const GatewayError(GatewayErrorCode.unsupported, '课表读取范围无效'),
      );
    }

    try {
      final snapshot = await _cacheStore.readSnapshot();
      if (snapshot == null) {
        final needsRefresh = await _needsRefresh();
        return GatewayResult<ScheduleOverview>(
          status:
              needsRefresh ? GatewayStatus.needsRefresh : GatewayStatus.missing,
          source: PersonalDataSource.none,
          warnings:
              needsRefresh ? const <String>['课表本地数据需要重新同步'] : const <String>[],
        );
      }

      final occurrences = <ScheduleCourseOccurrence>[];
      var termsWithoutStartDate = 0;
      final availableTermIds = snapshot.terms.keys.toList()..sort();
      final datedTerms = <_DatedScheduleTerm>[];
      for (final entry in snapshot.terms.entries) {
        final termStart = entry.value.semesterStart;
        if (termStart == null) {
          termsWithoutStartDate++;
          continue;
        }
        datedTerms.add(
          _DatedScheduleTerm(
            semesterId: entry.key,
            term: entry.value,
            start: _utcDate(termStart),
          ),
        );
      }
      datedTerms.sort((left, right) => left.start.compareTo(right.start));
      for (var index = 1; index < datedTerms.length; index++) {
        if (datedTerms[index - 1].start == datedTerms[index].start) {
          return _corruptedResult();
        }
      }

      for (var index = 0; index < datedTerms.length; index++) {
        final datedTerm = datedTerms[index];
        final termEndExclusive = index + 1 < datedTerms.length
            ? datedTerms[index + 1].start
            : datedTerm.start.add(_lastTermMaximumDuration);
        final effectiveStart = normalizedStart.isAfter(datedTerm.start)
            ? normalizedStart
            : datedTerm.start;
        final lastTermDate = termEndExclusive.subtract(const Duration(days: 1));
        final effectiveEnd =
            normalizedEnd.isBefore(lastTermDate) ? normalizedEnd : lastTermDate;
        if (effectiveEnd.isBefore(effectiveStart)) continue;
        occurrences.addAll(
          _occurrencesForTerm(
            semesterId: datedTerm.semesterId,
            term: datedTerm.term,
            semesterStart: datedTerm.start,
            start: effectiveStart,
            end: effectiveEnd,
          ),
        );
      }
      occurrences.sort(_compareOccurrences);

      return GatewayResult<ScheduleOverview>(
        data: ScheduleOverview(
          start: normalizedStart,
          end: normalizedEnd,
          availableSemesterIds: availableTermIds,
          occurrences: occurrences,
          termsWithoutStartDate: termsWithoutStartDate,
        ),
        status:
            snapshot.isStale ? GatewayStatus.stale : GatewayStatus.available,
        source: PersonalDataSource.localEncryptedVault,
        fetchedAt: snapshot.fetchedAt,
        expiresAt: snapshot.expiresAt,
        isStale: snapshot.isStale,
        warnings: termsWithoutStartDate == 0
            ? (snapshot.isStale
                ? const <String>['课表数据已过期，建议先同步']
                : const <String>[])
            : <String>[
                if (snapshot.isStale) '课表数据已过期，建议先同步',
                '部分课表缺少学期起始日期，无法计算指定日期课程',
              ],
      );
    } on PersonalSnapshotStoreException {
      return _corruptedResult();
    } on FormatException {
      return _corruptedResult();
    } catch (_) {
      return _corruptedResult();
    }
  }

  Future<bool> _needsRefresh() async {
    try {
      return await _needsResync?.call() ?? false;
    } catch (_) {
      return true;
    }
  }

  List<ScheduleCourseOccurrence> _occurrencesForTerm({
    required String semesterId,
    required ScheduleTermSnapshot term,
    required DateTime semesterStart,
    required DateTime start,
    required DateTime end,
  }) {
    final result = <ScheduleCourseOccurrence>[];
    for (final rawCourse in term.courses) {
      final course = _GatewayScheduleCourse.fromPayload(rawCourse);
      for (var day = start;
          !day.isAfter(end);
          day = day.add(const Duration(days: 1))) {
        final offset = day.difference(semesterStart).inDays;
        if (offset < 0 || day.weekday != course.weekday) continue;
        final academicWeek = offset ~/ 7 + 1;
        if (course.weeks.isNotEmpty && !course.weeks.contains(academicWeek)) {
          continue;
        }
        result.add(
          ScheduleCourseOccurrence(
            date: day,
            semesterId: semesterId,
            courseName: course.name,
            weekday: course.weekday,
            startSection: course.startSection,
            endSection: course.endSection,
            teacher: course.teacher,
            location: course.location,
          ),
        );
      }
    }
    return result;
  }

  GatewayResult<ScheduleOverview> _corruptedResult() {
    return GatewayResult<ScheduleOverview>(
      status: GatewayStatus.corrupted,
      source: PersonalDataSource.none,
      warnings: const <String>['课表本地加密数据无法验证，请重新同步'],
      error: const GatewayError(GatewayErrorCode.corrupted, '课表本地数据不可用'),
    );
  }

  static DateTime _utcDate(DateTime value) =>
      DateTime.utc(value.year, value.month, value.day);

  static int _compareOccurrences(
    ScheduleCourseOccurrence left,
    ScheduleCourseOccurrence right,
  ) {
    final date = left.date.compareTo(right.date);
    if (date != 0) return date;
    final section = left.startSection.compareTo(right.startSection);
    if (section != 0) return section;
    return left.courseName.compareTo(right.courseName);
  }
}

class _DatedScheduleTerm {
  const _DatedScheduleTerm({
    required this.semesterId,
    required this.term,
    required this.start,
  });

  final String semesterId;
  final ScheduleTermSnapshot term;
  final DateTime start;
}

class _GatewayScheduleCourse {
  const _GatewayScheduleCourse({
    required this.name,
    required this.weekday,
    required this.startSection,
    required this.endSection,
    required this.weeks,
    this.teacher,
    this.location,
  });

  final String name;
  final int weekday;
  final int startSection;
  final int endSection;
  final Set<int> weeks;
  final String? teacher;
  final String? location;

  factory _GatewayScheduleCourse.fromPayload(Map<String, dynamic> payload) {
    final name = _requiredText(payload['name']);
    final weekday = _requiredPositiveInt(payload['weekday']);
    final startSection = _requiredPositiveInt(payload['start_section']);
    final endSection = _requiredPositiveInt(payload['end_section']);
    if (weekday > 7 || endSection < startSection) {
      throw const FormatException('课表课程格式错误');
    }

    final rawWeeks = payload['weeks'];
    if (rawWeeks != null && rawWeeks is! Iterable) {
      throw const FormatException('课表课程格式错误');
    }
    final weeks = <int>{};
    for (final rawWeek in rawWeeks ?? const <dynamic>[]) {
      final week = _requiredPositiveInt(rawWeek);
      if (week > 60) throw const FormatException('课表课程格式错误');
      weeks.add(week);
    }

    return _GatewayScheduleCourse(
      name: name,
      weekday: weekday,
      startSection: startSection,
      endSection: endSection,
      weeks: weeks,
      teacher: _optionalText(payload['teacher']),
      location: _optionalText(payload['location']),
    );
  }
}

String _requiredText(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    throw const FormatException('课表课程格式错误');
  }
  return value.trim();
}

String? _optionalText(Object? value) {
  if (value == null) return null;
  if (value is! String) throw const FormatException('课表课程格式错误');
  final text = value.trim();
  return text.isEmpty ? null : text;
}

int _requiredPositiveInt(Object? value) {
  if (value is! num || value % 1 != 0 || value <= 0) {
    throw const FormatException('课表课程格式错误');
  }
  return value.toInt();
}
