import '../../campus_data/storage/personal_snapshot_models.dart';
import '../personal_data/models/academic_overview.dart';
import 'gateway_skill_support.dart';
import 'personal_skill.dart';
import 'skill_execution_context.dart';

class AcademicOverviewInput {
  const AcademicOverviewInput();
}

class AcademicTermSkillSummary {
  const AcademicTermSkillSummary({
    required this.year,
    required this.semester,
    required this.courseCount,
    required this.fetchedAt,
  });

  final String year;
  final int semester;
  final int courseCount;
  final DateTime fetchedAt;
}

class AcademicOverviewOutput {
  AcademicOverviewOutput({
    required this.acquiredCourseCount,
    required List<AcademicTermSkillSummary> coveredTerms,
    required this.hasRawAcademicOverview,
    required this.hasMissingData,
    required this.dataUpdatedAt,
  }) : coveredTerms = List<AcademicTermSkillSummary>.unmodifiable(coveredTerms);

  final int acquiredCourseCount;
  final List<AcademicTermSkillSummary> coveredTerms;
  final bool hasRawAcademicOverview;
  final bool hasMissingData;
  final DateTime? dataUpdatedAt;
}

class AcademicOverviewSkill
    implements PersonalSkill<AcademicOverviewInput, AcademicOverviewOutput> {
  static const String skillId = 'personal.academic.overview';
  static const int _maximumTerms = 24;

  @override
  String get id => skillId;

  @override
  SkillSensitivity get sensitivity => SkillSensitivity.medium;

  @override
  Set<PersonalDataType> get requiredDataTypes =>
      const <PersonalDataType>{PersonalDataType.academic};

  @override
  Future<SkillResult<AcademicOverviewOutput>> execute(
    AcademicOverviewInput input,
    SkillExecutionContext context,
  ) async {
    final gateway = await context.getAcademicOverview();
    final failure = gatewayFailure<AcademicOverviewOutput, AcademicOverview>(
      gateway,
      dataLabel: '成绩',
    );
    if (failure != null) return failure;

    final overview = gateway.data!;
    final terms = overview.terms.take(_maximumTerms).map(
          (term) => AcademicTermSkillSummary(
            year: term.year,
            semester: term.semester,
            courseCount: term.courseCount,
            fetchedAt: term.fetchedAt,
          ),
        );
    final truncated = overview.terms.length > _maximumTerms;
    final hasMissingData =
        overview.terms.isEmpty || !overview.hasAcademicSituation || truncated;
    return SkillResult<AcademicOverviewOutput>(
      value: AcademicOverviewOutput(
        acquiredCourseCount: overview.totalRecordedCourses,
        coveredTerms: terms.toList(growable: false),
        hasRawAcademicOverview: overview.hasAcademicSituation,
        hasMissingData: hasMissingData,
        dataUpdatedAt: gateway.fetchedAt,
      ),
      status: hasMissingData ? SkillStatus.partial : SkillStatus.success,
      evidence: <SkillEvidence>[
        gatewayEvidence(
          gateway,
          dataType: PersonalDataType.academic,
          scope: '成绩课程数量与学期覆盖概览',
        ),
      ],
      warnings: mergeWarnings(
        gateway.warnings,
        <String>[
          if (overview.terms.isEmpty) '尚未获取任何学期成绩',
          if (!overview.hasAcademicSituation) '原始学业情况概览缺失',
          if (truncated) '学期数量超过上限，仅返回最近 $_maximumTerms 个学期',
        ],
      ),
      containsPersonalData: true,
    );
  }
}
