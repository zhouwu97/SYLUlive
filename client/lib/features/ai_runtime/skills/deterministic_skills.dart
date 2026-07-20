import '../../campus_data/storage/personal_snapshot_models.dart';
import '../deterministic/academic_calculation_engine.dart';
import '../deterministic/competition_fit_engine.dart';
import '../deterministic/fitness_weekly_plan_engine.dart';
import '../deterministic/graduation_requirement_engine.dart';
import '../personal_data/models/academic_records.dart';
import 'gateway_skill_support.dart';
import 'personal_skill.dart';
import 'skill_execution_context.dart';

class EmptyDeterministicInput {
  const EmptyDeterministicInput();
}

class AcademicGpaOutput {
  const AcademicGpaOutput(this.result);
  final GpaResult result;
}

class AcademicCreditOutput {
  const AcademicCreditOutput(this.summary);
  final CreditSummary summary;
}

class AcademicFailureRiskOutput {
  const AcademicFailureRiskOutput(this.summary);
  final FailedCourseSummary summary;
}

abstract class _AcademicDeterministicSkill<O>
    implements PersonalSkill<EmptyDeterministicInput, O> {
  _AcademicDeterministicSkill([AcademicCalculationEngine? engine])
      : engine = engine ?? AcademicCalculationEngine();

  final AcademicCalculationEngine engine;

  @override
  Set<PersonalDataType> get requiredDataTypes =>
      const <PersonalDataType>{PersonalDataType.academic};

  Future<SkillResult<O>> calculate(
    SkillExecutionContext context,
    O Function(List<CourseGradeRecord> records) operation,
  ) async {
    final gateway = await context.getAcademicRecords();
    final failure =
        gatewayFailure<O, AcademicRecords>(gateway, dataLabel: '成绩');
    if (failure != null) return failure;
    return SkillResult<O>(
      value: operation(gateway.data!.courses),
      status: gateway.isStale ? SkillStatus.partial : SkillStatus.success,
      evidence: <SkillEvidence>[
        gatewayEvidence(
          gateway,
          dataType: PersonalDataType.academic,
          scope: '已同步成绩的确定性计算',
        ),
      ],
      warnings: gateway.warnings,
      containsPersonalData: true,
    );
  }
}

class AcademicGpaSkill extends _AcademicDeterministicSkill<AcademicGpaOutput> {
  AcademicGpaSkill([super.engine]);
  static const String skillId = 'personal.academic.gpa';
  @override
  String get id => skillId;
  @override
  SkillSensitivity get sensitivity => SkillSensitivity.high;
  @override
  Future<SkillResult<AcademicGpaOutput>> execute(
    EmptyDeterministicInput input,
    SkillExecutionContext context,
  ) =>
      calculate(context,
          (records) => AcademicGpaOutput(engine.calculateGpa(records)));
}

class AcademicCreditSummarySkill
    extends _AcademicDeterministicSkill<AcademicCreditOutput> {
  AcademicCreditSummarySkill([super.engine]);
  static const String skillId = 'personal.academic.credit_summary';
  @override
  String get id => skillId;
  @override
  SkillSensitivity get sensitivity => SkillSensitivity.high;
  @override
  Future<SkillResult<AcademicCreditOutput>> execute(
    EmptyDeterministicInput input,
    SkillExecutionContext context,
  ) =>
      calculate(
        context,
        (records) => AcademicCreditOutput(engine.calculateCredits(records)),
      );
}

class AcademicFailureRiskSkill
    extends _AcademicDeterministicSkill<AcademicFailureRiskOutput> {
  AcademicFailureRiskSkill([super.engine]);
  static const String skillId = 'personal.academic.failure_risk';
  @override
  String get id => skillId;
  @override
  SkillSensitivity get sensitivity => SkillSensitivity.high;
  @override
  Future<SkillResult<AcademicFailureRiskOutput>> execute(
    EmptyDeterministicInput input,
    SkillExecutionContext context,
  ) =>
      calculate(
        context,
        (records) =>
            AcademicFailureRiskOutput(engine.calculateFailures(records)),
      );
}

abstract interface class GraduationRuleProvider {
  Future<CurriculumRulePackage?> currentRules();
}

class GraduationReadinessOutput {
  const GraduationReadinessOutput(this.readiness);
  final GraduationReadiness readiness;
}

class GraduationReadinessSkill
    implements
        PersonalSkill<EmptyDeterministicInput, GraduationReadinessOutput> {
  GraduationReadinessSkill({
    required GraduationRuleProvider ruleProvider,
    GraduationRequirementEngine? engine,
  })  : _ruleProvider = ruleProvider,
        _engine = engine ?? GraduationRequirementEngine();

  static const String skillId = 'personal.graduation.readiness';
  final GraduationRuleProvider _ruleProvider;
  final GraduationRequirementEngine _engine;
  @override
  String get id => skillId;
  @override
  SkillSensitivity get sensitivity => SkillSensitivity.high;
  @override
  Set<PersonalDataType> get requiredDataTypes => const <PersonalDataType>{
        PersonalDataType.academic,
        PersonalDataType.erke,
      };

  @override
  Future<SkillResult<GraduationReadinessOutput>> execute(
    EmptyDeterministicInput input,
    SkillExecutionContext context,
  ) async {
    final academic = await context.getAcademicRecords();
    final erke = await context.getErkeOverview();
    final academicFailure =
        gatewayFailure<GraduationReadinessOutput, AcademicRecords>(
      academic,
      dataLabel: '成绩',
    );
    if (academicFailure != null) return academicFailure;
    final erkeFailure = gatewayFailure<GraduationReadinessOutput, dynamic>(
      erke,
      dataLabel: '二课',
    );
    if (erkeFailure != null) return erkeFailure;
    final rules = await _ruleProvider.currentRules();
    final readiness = _engine.evaluate(
      academic: academic.data!,
      erke: erke.data!,
      rules: rules,
    );
    return SkillResult<GraduationReadinessOutput>(
      value: GraduationReadinessOutput(readiness),
      status: rules == null || !rules.humanReviewed
          ? SkillStatus.partial
          : SkillStatus.success,
      evidence: <SkillEvidence>[
        gatewayEvidence(
          academic,
          dataType: PersonalDataType.academic,
          scope: '毕业清单所需成绩',
        ),
        gatewayEvidence(
          erke,
          dataType: PersonalDataType.erke,
          scope: '毕业清单所需二课概览',
        ),
      ],
      warnings: readiness.warnings,
      containsPersonalData: true,
    );
  }
}

abstract interface class CompetitionFitDataSource {
  Future<List<CompetitionCandidate>> candidates();
  Future<StudentCompetitionProfile> currentProfile();
}

class CompetitionFitOutput {
  CompetitionFitOutput(List<CompetitionFitResult> items)
      : items = List.unmodifiable(items.take(20));
  final List<CompetitionFitResult> items;
}

class CompetitionFitSkill
    implements PersonalSkill<EmptyDeterministicInput, CompetitionFitOutput> {
  CompetitionFitSkill(this._source, [CompetitionFitEngine? engine])
      : _engine = engine ?? CompetitionFitEngine();
  static const String skillId = 'personal.competition.fit';
  final CompetitionFitDataSource _source;
  final CompetitionFitEngine _engine;
  @override
  String get id => skillId;
  @override
  SkillSensitivity get sensitivity => SkillSensitivity.medium;
  @override
  Set<PersonalDataType> get requiredDataTypes =>
      const <PersonalDataType>{PersonalDataType.academic};

  @override
  Future<SkillResult<CompetitionFitOutput>> execute(
    EmptyDeterministicInput input,
    SkillExecutionContext context,
  ) async {
    final academic = await context.getAcademicRecords();
    final failure = gatewayFailure<CompetitionFitOutput, AcademicRecords>(
      academic,
      dataLabel: '学业画像',
    );
    if (failure != null) return failure;
    final ranked = _engine.rank(
      await _source.candidates(),
      await _source.currentProfile(),
    );
    return SkillResult<CompetitionFitOutput>(
      value: CompetitionFitOutput(ranked),
      status: SkillStatus.success,
      evidence: <SkillEvidence>[
        gatewayEvidence(
          academic,
          dataType: PersonalDataType.academic,
          scope: '竞赛适配所需最小化学业画像',
        ),
      ],
      containsPersonalData: true,
    );
  }
}

class FitnessWeeklyPlanInput {
  const FitnessWeeklyPlanInput({
    this.weekContaining,
    this.heightMeters,
    this.weightKg,
    this.reportsDiscomfort = false,
  });
  final DateTime? weekContaining;
  final double? heightMeters;
  final double? weightKg;
  final bool reportsDiscomfort;
}

class FitnessWeeklyPlanOutput {
  const FitnessWeeklyPlanOutput(this.plan);
  final FitnessWeeklyPlan plan;
}

class FitnessWeeklyPlanSkill
    implements PersonalSkill<FitnessWeeklyPlanInput, FitnessWeeklyPlanOutput> {
  FitnessWeeklyPlanSkill([FitnessWeeklyPlanEngine? engine])
      : _engine = engine ?? FitnessWeeklyPlanEngine();
  static const String skillId = 'personal.fitness.weekly_plan';
  final FitnessWeeklyPlanEngine _engine;
  @override
  String get id => skillId;
  @override
  SkillSensitivity get sensitivity => SkillSensitivity.medium;
  @override
  Set<PersonalDataType> get requiredDataTypes => const <PersonalDataType>{
        PersonalDataType.schedule,
        PersonalDataType.physical,
      };

  @override
  Future<SkillResult<FitnessWeeklyPlanOutput>> execute(
    FitnessWeeklyPlanInput input,
    SkillExecutionContext context,
  ) async {
    final anchor = input.weekContaining ?? context.now();
    final start = DateTime.utc(anchor.year, anchor.month, anchor.day)
        .subtract(Duration(days: anchor.weekday - 1));
    final end = start.add(const Duration(days: 6));
    final schedule = await context.getScheduleOverview(start: start, end: end);
    final physical = await context.getPhysicalOverview();
    if (!schedule.hasData) {
      return SkillResult<FitnessWeeklyPlanOutput>(
        status: SkillStatus.missingData,
        containsPersonalData: false,
        warnings: const <String>['缺少课表，无法确定空闲时间'],
      );
    }
    final occupiedDays =
        schedule.data!.occurrences.map((item) => item.date.weekday).toSet();
    final windows = <FitnessTimeWindow>[];
    for (var day = 0; day < 7; day++) {
      final date = start.add(Duration(days: day));
      // 阶段七暂不持有课表分钟级时间，保守地只在当天没有课程时安排窗口。
      if (occupiedDays.contains(date.weekday)) continue;
      const hour = 17;
      windows.add(
        FitnessTimeWindow(
          start: DateTime.utc(date.year, date.month, date.day, hour),
          end: DateTime.utc(date.year, date.month, date.day, hour + 1),
        ),
      );
    }
    final plan = _engine.build(
      freeWindows: windows,
      heightMeters: input.heightMeters,
      weightKg: input.weightKg,
      physicalOverviewAvailable: physical.hasData,
      physicalOverviewStale: physical.isStale,
      reportsDiscomfort: input.reportsDiscomfort,
    );
    return SkillResult<FitnessWeeklyPlanOutput>(
      value: FitnessWeeklyPlanOutput(plan),
      status: physical.hasData ? SkillStatus.success : SkillStatus.partial,
      evidence: <SkillEvidence>[
        gatewayEvidence(
          schedule,
          dataType: PersonalDataType.schedule,
          scope: '本周课表空闲窗口',
        ),
        if (physical.hasData)
          gatewayEvidence(
            physical,
            dataType: PersonalDataType.physical,
            scope: '最近体测概览',
          ),
      ],
      warnings: plan.safetyNotes,
      containsPersonalData: true,
    );
  }
}
