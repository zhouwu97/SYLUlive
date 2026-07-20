import '../personal_data/models/academic_records.dart';
import '../personal_data/models/erke_overview.dart';
import 'academic_calculation_engine.dart';

enum RequirementState {
  completed,
  notCompleted,
  unknown,
  blocked,
  notApplicable
}

class CurriculumRulePackage {
  CurriculumRulePackage({
    required this.policyId,
    required this.effectiveFrom,
    required this.college,
    required this.major,
    required this.grade,
    required this.requiredTotalCredits,
    required this.requiredErkeScore,
    required this.sourceDocument,
    required this.publishedAt,
    required this.humanReviewed,
  });

  final String policyId;
  final DateTime effectiveFrom;
  final String college;
  final String major;
  final String grade;
  final double requiredTotalCredits;
  final double requiredErkeScore;
  final String sourceDocument;
  final DateTime publishedAt;
  final bool humanReviewed;
}

class GraduationRequirementItem {
  const GraduationRequirementItem({
    required this.id,
    required this.label,
    required this.state,
    required this.summary,
  });
  final String id;
  final String label;
  final RequirementState state;
  final String summary;
}

class GraduationReadiness {
  GraduationReadiness({
    required this.policyId,
    required List<GraduationRequirementItem> items,
    required List<String> warnings,
  })  : items = List.unmodifiable(items),
        warnings = List.unmodifiable(warnings);
  final String policyId;
  final List<GraduationRequirementItem> items;
  final List<String> warnings;
}

class GraduationRequirementEngine {
  GraduationRequirementEngine({AcademicCalculationEngine? academicEngine})
      : _academicEngine = academicEngine ?? AcademicCalculationEngine();

  final AcademicCalculationEngine _academicEngine;

  GraduationReadiness evaluate({
    required AcademicRecords academic,
    required ErkeOverview erke,
    required CurriculumRulePackage? rules,
  }) {
    if (rules == null || !rules.humanReviewed) {
      return GraduationReadiness(
        policyId: rules?.policyId ?? 'unknown',
        items: const <GraduationRequirementItem>[
          GraduationRequirementItem(
            id: 'policy',
            label: '培养方案',
            state: RequirementState.blocked,
            summary: '缺少已人工审核的适用规则包',
          ),
        ],
        warnings: const <String>['不能形成最终毕业结论'],
      );
    }
    final credits = _academicEngine.calculateCredits(academic.courses);
    final failures = _academicEngine.calculateFailures(academic.courses);
    final erkeScore = erke.earnedTotal;
    return GraduationReadiness(
      policyId: rules.policyId,
      items: <GraduationRequirementItem>[
        GraduationRequirementItem(
          id: 'total_credits',
          label: '总学分',
          state: credits.unknownCredits > 0
              ? RequirementState.unknown
              : credits.passedCredits >= rules.requiredTotalCredits
                  ? RequirementState.completed
                  : RequirementState.notCompleted,
          summary: '${credits.passedCredits} / ${rules.requiredTotalCredits}',
        ),
        GraduationRequirementItem(
          id: 'required_courses',
          label: '必修课程',
          state: credits.requiredFailedCredits > 0
              ? RequirementState.notCompleted
              : failures.unknownCourses.isNotEmpty
                  ? RequirementState.unknown
                  : RequirementState.completed,
          summary: '未通过必修学分 ${credits.requiredFailedCredits}',
        ),
        GraduationRequirementItem(
          id: 'erke',
          label: '二课',
          state: erkeScore == null
              ? RequirementState.unknown
              : erkeScore >= rules.requiredErkeScore
                  ? RequirementState.completed
                  : RequirementState.notCompleted,
          summary: erkeScore == null
              ? '数据不足'
              : '$erkeScore / ${rules.requiredErkeScore}',
        ),
        const GraduationRequirementItem(
          id: 'practice',
          label: '实践环节',
          state: RequirementState.blocked,
          summary: '尚未接入结构化数据',
        ),
      ],
      warnings: const <String>['结论仅覆盖当前已同步数据和结构化规则'],
    );
  }
}
