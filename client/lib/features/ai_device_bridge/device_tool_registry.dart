import '../ai_runtime/deterministic/academic_calculation_engine.dart';
import '../ai_runtime/personal_data/gateway/gateway_result.dart';
import '../ai_runtime/personal_data/gateway/personal_data_gateway.dart';

import 'device_automation_gateway.dart';
import 'device_job_models.dart';

class DeviceToolExecutionException implements Exception {
  const DeviceToolExecutionException(this.code);

  final String code;

  @override
  String toString() => 'DeviceToolExecutionException($code)';
}

/// 设备侧唯一的 Tool 白名单。刷新只能通过 DeviceAutomationGateway 的受控闭包执行。
class DeviceToolRegistry {
  DeviceToolRegistry({AcademicCalculationEngine? academicEngine})
      : _academicEngine = academicEngine ?? AcademicCalculationEngine();

  static const supportedToolNames = <String>{
    'device.academic.get_cached_overview',
    'device.academic.get_cached_grade_summary',
    'device.academic.get_cached_risk_context',
    'device.schedule.get_cached_week',
    'device.academic.get_credit_summary',
    'device.erke.get_cached_overview',
    'device.academic.ensure_fresh_overview',
    'device.academic.ensure_fresh_grade_summary',
    'device.academic.ensure_fresh_risk_context',
    'device.schedule.ensure_fresh_week',
    'device.academic.ensure_fresh_credit_summary',
    'device.erke.ensure_fresh_overview',
  };

  final AcademicCalculationEngine _academicEngine;

  Future<DeviceToolExecutionResult> execute(
    DeviceToolJob job,
    PersonalDataGateway? gateway, {
    DeviceAutomationGateway? automationGateway,
  }) async {
    return switch (job.toolName) {
      'device.academic.get_cached_overview' => _academicOverview(job, gateway),
      'device.academic.get_cached_grade_summary' => _gradeSummary(job, gateway),
      'device.academic.get_cached_risk_context' => _riskContext(job, gateway),
      'device.schedule.get_cached_week' => _scheduleWeek(job, gateway),
      'device.academic.get_credit_summary' => _creditSummary(job, gateway),
      'device.erke.get_cached_overview' => _erkeOverview(job, gateway),
      'device.academic.ensure_fresh_overview' => _academicOverview(
          job,
          gateway,
          automationGateway: automationGateway,
        ),
      'device.academic.ensure_fresh_grade_summary' => _gradeSummary(
          job,
          gateway,
          automationGateway: automationGateway,
        ),
      'device.academic.ensure_fresh_risk_context' => _riskContext(
          job,
          gateway,
          automationGateway: automationGateway,
        ),
      'device.schedule.ensure_fresh_week' => _scheduleWeek(
          job,
          gateway,
          automationGateway: automationGateway,
        ),
      'device.academic.ensure_fresh_credit_summary' => _creditSummary(
          job,
          gateway,
          automationGateway: automationGateway,
        ),
      'device.erke.ensure_fresh_overview' => _erkeOverview(
          job,
          gateway,
          automationGateway: automationGateway,
        ),
      _ => throw const DeviceToolExecutionException('tool_not_allowed'),
    };
  }

  Future<DeviceToolExecutionResult> _gradeSummary(
    DeviceToolJob job,
    PersonalDataGateway? gateway, {
    DeviceAutomationGateway? automationGateway,
  }) async {
    return _academicGradeProjection(
      job,
      gateway,
      automationGateway: automationGateway,
    );
  }

  Future<DeviceToolExecutionResult> _riskContext(
    DeviceToolJob job,
    PersonalDataGateway? gateway, {
    DeviceAutomationGateway? automationGateway,
  }) async {
    return _academicGradeProjection(
      job,
      gateway,
      automationGateway: automationGateway,
    );
  }

  Future<DeviceToolExecutionResult> _academicGradeProjection(
    DeviceToolJob job,
    PersonalDataGateway? gateway, {
    DeviceAutomationGateway? automationGateway,
  }) async {
    final freshness = await _prepareFreshness(
      job,
      PersonalDataType.academic,
      automationGateway,
    );
    _requireExactRequest(
      job,
      const <String>['grades'],
      freshness == null ? const <String>{} : const <String>{'max_age_seconds'},
    );
    final result = await _read(
      gateway,
      automationGateway,
      (reader) => reader.getAcademicRecords(),
    );
    final records = _requiredData(result);
    final credits = _academicEngine.calculateCredits(records.courses);
    final gpa = _academicEngine.calculateGpa(records.courses);
    final failures = _academicEngine.calculateFailures(records.courses);
    final failedCourses = failures.failedCourses.take(500).map((course) {
      final score =
          course.score ?? double.tryParse(course.gradeText ?? '') ?? 0;
      return <String, dynamic>{
        'course_name': course.courseName,
        'grade': score,
        'credits': course.credit,
      };
    }).toList(growable: false);
    return DeviceToolExecutionResult(
      _envelope(
        result,
        data: <String, dynamic>{
          'course_count': records.courses.length,
          'earned_credits': credits.passedCredits,
          'weighted_gpa': gpa.gpa ?? 0,
          'failed_courses': failedCourses,
        },
        freshness: freshness,
      ),
    );
  }

  Future<DeviceToolExecutionResult> _academicOverview(
    DeviceToolJob job,
    PersonalDataGateway? gateway, {
    DeviceAutomationGateway? automationGateway,
  }) async {
    final freshness = await _prepareFreshness(
      job,
      PersonalDataType.academic,
      automationGateway,
    );
    _requireExactRequest(
      job,
      const <String>['academic'],
      freshness == null ? const <String>{} : const <String>{'max_age_seconds'},
    );
    final result = await _read(
      gateway,
      automationGateway,
      (reader) => reader.getAcademicOverview(),
    );
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
        freshness: freshness,
      ),
    );
  }

  Future<DeviceToolExecutionResult> _scheduleWeek(
    DeviceToolJob job,
    PersonalDataGateway? gateway, {
    DeviceAutomationGateway? automationGateway,
  }) async {
    final freshness = await _prepareFreshness(
      job,
      PersonalDataType.schedule,
      automationGateway,
    );
    _requireExactRequest(
      job,
      const <String>['schedule'],
      freshness == null
          ? const <String>{'week_containing'}
          : const <String>{'week_containing', 'max_age_seconds'},
    );
    final anchor = _requiredDate(job.arguments['week_containing']);
    final start = DateTime.utc(anchor.year, anchor.month, anchor.day)
        .subtract(Duration(days: anchor.weekday - 1));
    final end = start.add(const Duration(days: 6));
    final result = await _read(
      gateway,
      automationGateway,
      (reader) => reader.getScheduleOverview(start: start, end: end),
    );
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
        freshness: freshness,
      ),
    );
  }

  Future<DeviceToolExecutionResult> _creditSummary(
    DeviceToolJob job,
    PersonalDataGateway? gateway, {
    DeviceAutomationGateway? automationGateway,
  }) async {
    final freshness = await _prepareFreshness(
      job,
      PersonalDataType.academic,
      automationGateway,
    );
    _requireExactRequest(
      job,
      const <String>['academic'],
      freshness == null ? const <String>{} : const <String>{'max_age_seconds'},
    );
    final result = await _read(
      gateway,
      automationGateway,
      (reader) => reader.getAcademicRecords(),
    );
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
        freshness: freshness,
      ),
    );
  }

  Future<DeviceToolExecutionResult> _erkeOverview(
    DeviceToolJob job,
    PersonalDataGateway? gateway, {
    DeviceAutomationGateway? automationGateway,
  }) async {
    final freshness = await _prepareFreshness(
      job,
      PersonalDataType.erke,
      automationGateway,
    );
    _requireExactRequest(
      job,
      const <String>['erke'],
      freshness == null ? const <String>{} : const <String>{'max_age_seconds'},
    );
    final result = await _read(
      gateway,
      automationGateway,
      (reader) => reader.getErkeOverview(),
    );
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
        freshness: freshness,
      ),
    );
  }

  Future<GatewayResult<T>> _read<T>(
    PersonalDataGateway? gateway,
    DeviceAutomationGateway? automationGateway,
    DeviceDataQuery<T> query,
  ) {
    if (automationGateway != null) return automationGateway.read(query);
    final reader = gateway;
    if (reader == null) {
      throw const DeviceToolExecutionException('device_context_unavailable');
    }
    return query(reader);
  }

  Future<EnsureFreshResult?> _prepareFreshness(
    DeviceToolJob job,
    PersonalDataType type,
    DeviceAutomationGateway? automationGateway,
  ) async {
    if (!_isEnsureFresh(job)) return null;
    if (automationGateway == null) {
      throw const DeviceToolExecutionException('device_automation_unavailable');
    }
    final requested = job.arguments['max_age_seconds'];
    if (requested is! num || requested % 1 != 0 || requested <= 0) {
      throw const DeviceToolExecutionException('invalid_tool_arguments');
    }
    // 设备最终限制不能被模型传入的 max_age_seconds 绕过。
    final ceiling = switch (type) {
      PersonalDataType.academic => 5 * 60,
      PersonalDataType.schedule => 10 * 60,
      PersonalDataType.erke => 30 * 60,
    };
    final seconds = requested.toInt().clamp(ceiling, 24 * 60 * 60);
    final ensured = await automationGateway.ensureFresh(
      type,
      maxAge: Duration(seconds: seconds),
    );
    if (!ensured.after.isFreshAt(DateTime.now(), Duration(seconds: seconds))) {
      throw const DeviceToolExecutionException('device_refresh_not_fresh');
    }
    return ensured;
  }

  static bool _isEnsureFresh(DeviceToolJob job) =>
      job.toolName.contains('.ensure_fresh_');

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
    EnsureFreshResult? freshness,
  }) {
    final partial = isPartial || result.status == GatewayStatus.stale;
    final source = freshness?.refreshPerformed == true
        ? PersonalDataSource.remoteEduFetch.wireValue
        : result.source.wireValue;
    final envelope = <String, dynamic>{
      'data': data,
      'source': source,
      'fetched_at': _time(result.fetchedAt),
      'expires_at': _time(result.expiresAt),
      'is_stale': result.isStale || result.status == GatewayStatus.stale,
      'is_partial': partial,
      'warnings': <String>{
        ...result.warnings,
        ...extraWarnings,
        if (freshness?.warning case final warning?) warning,
      }.toList(growable: false),
      'evidence': <Map<String, dynamic>>[
        <String, dynamic>{
          'source': source,
          'fetched_at': _time(result.fetchedAt),
          'expires_at': _time(result.expiresAt),
          'is_stale': result.isStale || result.status == GatewayStatus.stale,
        },
      ],
    };
    if (freshness != null) {
      envelope['freshness'] = <String, dynamic>{
        'before': _freshnessLabel(freshness.before),
        'after': _freshnessLabel(freshness.after),
      };
      envelope['refresh_performed'] = freshness.refreshPerformed;
    }
    return envelope;
  }

  static String _freshnessLabel(FreshnessState value) {
    if (value.isStale || value.fetchedAt == null) return 'stale';
    final expires = value.expiresAt;
    if (expires != null && !expires.isAfter(DateTime.now())) return 'stale';
    return 'fresh';
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
