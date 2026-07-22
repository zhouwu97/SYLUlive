import '../skills/academic_overview_skill.dart';
import '../skills/competition_search_skill.dart';
import '../skills/competition_advisor_skills.dart';
import '../skills/erke_overview_skill.dart';
import '../skills/deterministic_skills.dart';
import '../skills/physical_overview_skill.dart';
import '../skills/schedule_skill_models.dart';
import '../skills/today_schedule_skill.dart';
import '../skills/week_schedule_skill.dart';
import 'tool_call_models.dart';

class ValidatedToolCall {
  const ValidatedToolCall({required this.call, required this.input});

  final LocalToolCall call;
  final Object input;
}

class ToolCallValidationException implements Exception {
  const ToolCallValidationException(this.message);

  final String message;
}

class LocalToolCallValidator {
  const LocalToolCallValidator();
  static const Set<String> _forbiddenKeys = <String>{
    'app_user_id',
    'user_id',
    'student_id',
    'vault_path',
    'database_key',
    'provider_api_key',
    'api_key',
    'token',
    'cookie',
  };

  ValidatedToolCall validate(LocalToolCall call) {
    if (call.id.isEmpty || call.id.length > 128) {
      throw const ToolCallValidationException('Tool Call ID 无效');
    }
    _rejectForbiddenKeys(call.arguments);
    final input = switch (call.tool) {
      TodayScheduleSkill.skillId => _today(call.arguments),
      WeekScheduleSkill.skillId => _week(call.arguments),
      AcademicOverviewSkill.skillId => _empty(
          call.arguments,
          const AcademicOverviewInput(),
        ),
      PhysicalOverviewSkill.skillId => _empty(
          call.arguments,
          const PhysicalOverviewInput(),
        ),
      ErkeOverviewSkill.skillId => _empty(
          call.arguments,
          const ErkeOverviewInput(),
        ),
      CompetitionSearchSkill.skillId => _competition(call.arguments),
      CompetitionCapabilityProfileSkill.skillId => _empty(
          call.arguments,
          const EmptyCompetitionAdvisorInput(),
        ),
      ExplainCompetitionMatchesSkill.skillId => _empty(
          call.arguments,
          const EmptyCompetitionAdvisorInput(),
        ),
      AcademicGpaSkill.skillId ||
      AcademicCreditSummarySkill.skillId ||
      AcademicFailureRiskSkill.skillId ||
      GraduationReadinessSkill.skillId =>
        _empty(
          call.arguments,
          const EmptyDeterministicInput(),
        ),
      FitnessWeeklyPlanSkill.skillId => _fitness(call.arguments),
      _ => throw const ToolCallValidationException('未知 Tool ID'),
    };
    return ValidatedToolCall(call: call, input: input);
  }

  Object _today(Map<String, dynamic> arguments) {
    _requireOnly(arguments, const <String>{'date'});
    final raw = arguments['date'];
    if (raw == null) return const TodayScheduleInput();
    return TodayScheduleInput(date: _date(raw));
  }

  Object _week(Map<String, dynamic> arguments) {
    _requireOnly(arguments, const <String>{'start', 'end', 'week_containing'});
    final anchor = arguments['week_containing'];
    final start = arguments['start'];
    final end = arguments['end'];
    if (anchor != null) {
      if (start != null || end != null) {
        throw const ToolCallValidationException('本周课表参数冲突');
      }
      return WeekScheduleInput.containing(_date(anchor));
    }
    if (start == null && end == null) return const WeekScheduleInput();
    if (start == null || end == null) {
      throw const ToolCallValidationException('本周课表日期范围不完整');
    }
    return WeekScheduleInput(start: _date(start), end: _date(end));
  }

  Object _competition(Map<String, dynamic> arguments) {
    _requireOnly(arguments, const <String>{
      'keyword',
      'category_slug',
      'limit',
    });
    final keyword = arguments['keyword'];
    final category = arguments['category_slug'];
    final limit = arguments['limit'] ?? 10;
    if (keyword is! String ||
        category != null && category is! String ||
        limit is! num ||
        limit % 1 != 0) {
      throw const ToolCallValidationException('竞赛检索参数无效');
    }
    final normalizedKeyword = keyword.trim();
    final normalizedCategory = (category as String?)?.trim() ?? '';
    if (normalizedKeyword.isEmpty ||
        normalizedKeyword.length >
            CompetitionSearchSkill.maximumKeywordLength ||
        normalizedCategory.length > 64 ||
        limit < 1 ||
        limit > CompetitionSearchSkill.maximumResultCount) {
      throw const ToolCallValidationException('竞赛检索参数无效');
    }
    return CompetitionSearchInput(
      keyword: keyword,
      categorySlug: category,
      limit: limit.toInt(),
    );
  }

  Object _empty(Map<String, dynamic> arguments, Object input) {
    if (arguments.isNotEmpty) {
      throw const ToolCallValidationException('该 Tool 不接受参数');
    }
    return input;
  }

  Object _fitness(Map<String, dynamic> arguments) {
    _requireOnly(arguments, const <String>{
      'week_containing',
      'height_meters',
      'weight_kg',
      'reports_discomfort',
    });
    final height = arguments['height_meters'];
    final weight = arguments['weight_kg'];
    final discomfort = arguments['reports_discomfort'];
    if (height != null && height is! num ||
        weight != null && weight is! num ||
        discomfort != null && discomfort is! bool) {
      throw const ToolCallValidationException('运动计划参数无效');
    }
    final heightValue = (height as num?)?.toDouble();
    final weightValue = (weight as num?)?.toDouble();
    if (heightValue != null && (heightValue < 1.2 || heightValue > 2.3) ||
        weightValue != null && (weightValue < 30 || weightValue > 250)) {
      throw const ToolCallValidationException('身高或体重超出允许范围');
    }
    final rawWeek = arguments['week_containing'];
    return FitnessWeeklyPlanInput(
      weekContaining: rawWeek == null ? null : _date(rawWeek),
      heightMeters: heightValue,
      weightKg: weightValue,
      reportsDiscomfort: discomfort,
    );
  }

  DateTime _date(Object raw) {
    if (raw is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw)) {
      throw const ToolCallValidationException('日期参数必须为 YYYY-MM-DD');
    }
    final parsed = DateTime.tryParse('${raw}T00:00:00Z');
    if (parsed == null || parsed.toIso8601String().substring(0, 10) != raw) {
      throw const ToolCallValidationException('日期参数无效');
    }
    return parsed;
  }

  void _requireOnly(Map<String, dynamic> arguments, Set<String> allowed) {
    if (arguments.keys.any((key) => !allowed.contains(key))) {
      throw const ToolCallValidationException('Tool 参数包含未允许字段');
    }
  }

  void _rejectForbiddenKeys(Object? value) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key.toString().trim().toLowerCase();
        if (_forbiddenKeys.contains(key)) {
          throw const ToolCallValidationException('Tool 参数包含敏感标识');
        }
        _rejectForbiddenKeys(entry.value);
      }
    } else if (value is Iterable) {
      for (final item in value) {
        _rejectForbiddenKeys(item);
      }
    }
  }
}
