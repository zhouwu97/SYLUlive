import '../../campus_data/storage/personal_snapshot_models.dart';
import '../personal_data/models/physical_overview.dart';
import 'gateway_skill_support.dart';
import 'personal_skill.dart';
import 'skill_execution_context.dart';

class PhysicalOverviewInput {
  const PhysicalOverviewInput();
}

class PhysicalMetricSkillSummary {
  const PhysicalMetricSkillSummary({
    required this.name,
    required this.result,
    required this.grade,
    required this.score,
  });

  final String name;
  final String result;
  final String grade;
  final double? score;
}

class PhysicalOverviewOutput {
  PhysicalOverviewOutput({
    required this.latestYear,
    required this.totalGrade,
    required this.totalScore,
    required List<PhysicalMetricSkillSummary> metrics,
    required this.bmiInputsAvailable,
    required this.dataUpdatedAt,
  }) : metrics = List<PhysicalMetricSkillSummary>.unmodifiable(metrics);

  final String latestYear;
  final String totalGrade;
  final double? totalScore;
  final List<PhysicalMetricSkillSummary> metrics;
  final bool bmiInputsAvailable;
  final DateTime? dataUpdatedAt;
}

class PhysicalOverviewSkill
    implements PersonalSkill<PhysicalOverviewInput, PhysicalOverviewOutput> {
  static const String skillId = 'personal.physical.overview';
  static const int _maximumMetrics = 20;

  @override
  String get id => skillId;

  @override
  SkillSensitivity get sensitivity => SkillSensitivity.medium;

  @override
  Set<PersonalDataType> get requiredDataTypes =>
      const <PersonalDataType>{PersonalDataType.physical};

  @override
  Future<SkillResult<PhysicalOverviewOutput>> execute(
    PhysicalOverviewInput input,
    SkillExecutionContext context,
  ) async {
    final gateway = await context.getPhysicalOverview();
    final failure = gatewayFailure<PhysicalOverviewOutput, PhysicalOverview>(
      gateway,
      dataLabel: '体测',
    );
    if (failure != null) return failure;

    final overview = gateway.data!;
    final metrics = overview.metrics.take(_maximumMetrics).map(
          (metric) => PhysicalMetricSkillSummary(
            name: metric.name,
            result: metric.result,
            grade: metric.grade,
            score: metric.score,
          ),
        );
    final metricNames = overview.metrics.map((item) => item.name);
    final hasHeight = metricNames.any((name) => name.contains('身高'));
    final hasWeight = metricNames.any(
      (name) => name.contains('体重') || name.toUpperCase().contains('BMI'),
    );
    final truncated = overview.metrics.length > _maximumMetrics;
    return SkillResult<PhysicalOverviewOutput>(
      value: PhysicalOverviewOutput(
        latestYear: overview.latestYear,
        totalGrade: overview.totalGrade,
        totalScore: overview.totalScore,
        metrics: metrics.toList(growable: false),
        bmiInputsAvailable: hasHeight && hasWeight,
        dataUpdatedAt: gateway.fetchedAt,
      ),
      status: truncated ? SkillStatus.partial : SkillStatus.success,
      evidence: <SkillEvidence>[
        gatewayEvidence(
          gateway,
          dataType: PersonalDataType.physical,
          scope: '最近学年体测概览',
        ),
      ],
      warnings: mergeWarnings(
        gateway.warnings,
        <String>[
          if (truncated) '体测项目超过上限，仅返回前 $_maximumMetrics 项',
        ],
      ),
      containsPersonalData: true,
    );
  }
}
