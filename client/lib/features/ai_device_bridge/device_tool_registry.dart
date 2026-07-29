import '../ai_runtime/deterministic/academic_calculation_engine.dart';
import '../ai_runtime/personal_data/gateway/gateway_result.dart';
import '../ai_runtime/personal_data/gateway/personal_data_gateway.dart';

import 'device_job_models.dart';

class DeviceToolExecutionException implements Exception {
  const DeviceToolExecutionException(this.code);

  final String code;

  @override
  String toString() => 'DeviceToolExecutionException($code)';
}

/// 设备侧唯一的 Tool 白名单。这里只读既有 PersonalDataGateway，绝不触发刷新或登录。
class DeviceToolRegistry {
  DeviceToolRegistry({AcademicCalculationEngine? academicEngine})
      : _academicEngine = academicEngine ?? AcademicCalculationEngine();

  static const supportedToolNames = <String>{
    'device.academic.get_cached_overview',
    'device.schedule.get_cached_week',
    'device.academic.get_credit_summary',
    'device.erke.get_cached_overview',
  };

  final AcademicCalculationEngine _academicEngine;

  Future<DeviceToolExecutionResult> execute(
    DeviceToolJob job,
    PersonalDataGateway gateway,
  ) async {
    return switch (job.toolName) {
      'device.academic.get_cached_overview' => _academicOverview(job, gateway),
      'device.schedule.get_cached_week' => _scheduleWeek(job, gateway),
      'device.academic.get_credit_summary' => _creditSummary(job, gateway),
      'device.erke.get_cached_overview' => _erkeOverview(job, gateway),
      _ => throw const DeviceToolExecutionException('tool_not_allowed'),
    };
  }

  Future<DeviceToolExecutionResult> _academicOverview(
    DeviceToolJob job,
    PersonalDataGateway gateway,
  ) async {
    _requireExactRequest(job, const <String>['academic'], const <String>{});
    final result = await gateway.getAcademicOverview();
    final data = _requiredData(result);
    return DeviceToolExecutionResult(
      _envelope(
        result,
        data: <String, dynamic>{
          'total_recorded_courses': data.totalRecordedCourses,
          'covered_term_count': data.terms.length,
          'covered_terms': data.terms
              .map(
                (term) => <String, dynamic>{
                  'year': term.year,
                  'semester': term.semester,
                  'course_count': term.courseCount,
                },
              )
              .toList(growable: false),
          'academic_situation_available': data.hasAcademicSituation,
        },
      ),
    );
  }

  Future<DeviceToolExecutionResult> _scheduleWeek(
    DeviceToolJob job,
    PersonalDataGateway gateway,
  ) async {
    _requireExactRequest(
      job,
      const <String>['schedule'],
      const <String>{'week_containing'},
    );
    final anchor = _requiredDate(job.arguments['week_containing']);
    final start = DateTime.utc(anchor.year, anchor.month, anchor.day)
        .subtract(Duration(days: anchor.weekday - 1));
    final end = start.add(const Duration(days: 6));
    final result = await gateway.getScheduleOverview(start: start, end: end);
    final data = _requiredData(result);
    const maxCourses = 32;
    final courses = data.occurrences
        .take(maxCourses)
        .map(
          (course) => <String, dynamic>{
            'date': _date(course.date),
            'course_name': course.courseName,
            'start_section': course.startSection,
            'end_section': course.endSection,
          },
        )
        .toList(growable: false);
    return DeviceToolExecutionResult(
      _envelope(
        result,
        isPartial: data.termsWithoutStartDate > 0 ||
            data.occurrences.length > maxCourses,
        extraWarnings: <String>[
          if (data.termsWithoutStartDate > 0) '部分学期缺少起始日期',
          if (data.occurrences.length > maxCourses)
            '本周课程数量超过上限，仅返回前 $maxCourses 条',
        ],
        data: <String, dynamic>{
          'week_start': _date(start),
          'week_end': _date(end),
          'courses': courses,
        },
      ),
    );
  }

  Future<DeviceToolExecutionResult> _creditSummary(
    DeviceToolJob job,
    PersonalDataGateway gateway,
  ) async {
    _requireExactRequest(job, const <String>['academic'], const <String>{});
    final result = await gateway.getAcademicRecords();
    final data = _requiredData(result);
    final summary = _academicEngine.calculateCredits(data.courses);
    return DeviceToolExecutionResult(
      _envelope(
        result,
        data: <String, dynamic>{
          'attempted_credits': summary.attemptedCredits,
          'passed_credits': summary.passedCredits,
          'failed_credits': summary.failedCredits,
          'required_failed_credits': summary.requiredFailedCredits,
          'unknown_credits': summary.unknownCredits,
        },
      ),
    );
  }

  Future<DeviceToolExecutionResult> _erkeOverview(
    DeviceToolJob job,
    PersonalDataGateway gateway,
  ) async {
    _requireExactRequest(job, const <String>['erke'], const <String>{});
    final result = await gateway.getErkeOverview();
    final data = _requiredData(result);
    return DeviceToolExecutionResult(
      _envelope(
        result,
        data: <String, dynamic>{
          'earned_total': data.earnedTotal,
          'required_total': data.requiredTotal,
          'unmet_categories': data.categories
              .where((item) => !item.meetsNumerically)
              .map(
                (item) => <String, dynamic>{
                  'name': item.name,
                  'gap':
                      (item.required - item.earned).clamp(0, double.infinity),
                },
              )
              .toList(growable: false),
          'activity_count': data.activityCount,
          'latest_activity_date': data.latestActivityDate,
        },
      ),
    );
  }

  T _requiredData<T>(GatewayResult<T> result) {
    if (result.data != null &&
        (result.status == GatewayStatus.available ||
            result.status == GatewayStatus.stale)) {
      return result.data!;
    }
    throw DeviceToolExecutionException(_gatewayErrorCode(result.status));
  }

  Map<String, dynamic> _envelope<T>(
    GatewayResult<T> result, {
    required Map<String, dynamic> data,
    bool isPartial = false,
    List<String> extraWarnings = const <String>[],
  }) {
    final partial = isPartial || result.status == GatewayStatus.stale;
    return <String, dynamic>{
      'data': data,
      'source': result.source.wireValue,
      'fetched_at': _time(result.fetchedAt),
      'expires_at': _time(result.expiresAt),
      'is_stale': result.isStale || result.status == GatewayStatus.stale,
      'is_partial': partial,
      'warnings': <String>{...result.warnings, ...extraWarnings}
          .toList(growable: false),
      'evidence': <Map<String, dynamic>>[
        <String, dynamic>{
          'source': result.source.wireValue,
          'fetched_at': _time(result.fetchedAt),
          'expires_at': _time(result.expiresAt),
          'is_stale': result.isStale || result.status == GatewayStatus.stale,
        },
      ],
    };
  }

  void _requireExactRequest(
    DeviceToolJob job,
    List<String> requiredDataTypes,
    Set<String> allowedArgumentKeys,
  ) {
    if (!_sameStringSet(job.requiredDataTypes, requiredDataTypes) ||
        !job.arguments.keys.every(allowedArgumentKeys.contains)) {
      throw const DeviceToolExecutionException('invalid_device_job');
    }
  }

  static bool _sameStringSet(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    return left.toSet().length == left.length &&
        left.toSet().containsAll(right);
  }

  static DateTime _requiredDate(Object? value) {
    if (value is! String || value.length > 32) {
      throw const DeviceToolExecutionException('invalid_tool_arguments');
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      throw const DeviceToolExecutionException('invalid_tool_arguments');
    }
    return parsed.toUtc();
  }

  static String _gatewayErrorCode(GatewayStatus status) => switch (status) {
        GatewayStatus.missing ||
        GatewayStatus.needsRefresh =>
          'local_data_missing',
        GatewayStatus.corrupted => 'local_cache_corrupted',
        GatewayStatus.accountMismatch ||
        GatewayStatus.closed =>
          'device_context_unavailable',
        GatewayStatus.unsupported => 'local_data_unsupported',
        GatewayStatus.available ||
        GatewayStatus.stale =>
          'local_data_unavailable',
      };

  static String _date(DateTime value) =>
      value.toUtc().toIso8601String().substring(0, 10);

  static String? _time(DateTime? value) => value?.toUtc().toIso8601String();
}
