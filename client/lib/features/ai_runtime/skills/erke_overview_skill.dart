import '../../campus_data/storage/personal_snapshot_models.dart';
import '../personal_data/models/erke_overview.dart';
import 'gateway_skill_support.dart';
import 'personal_skill.dart';
import 'skill_execution_context.dart';

class ErkeOverviewInput {
  const ErkeOverviewInput();
}

class ErkeCategorySkillSummary {
  const ErkeCategorySkillSummary({
    required this.code,
    required this.name,
    required this.required,
    required this.earned,
    required this.meetsNumerically,
  });

  final String code;
  final String name;
  final double required;
  final double earned;
  final bool meetsNumerically;
}

class ErkeActivitySkillSummary {
  const ErkeActivitySkillSummary({
    required this.item,
    required this.score,
    required this.date,
    required this.category,
  });

  final String item;
  final double score;
  final String date;
  final String category;
}

class ErkeOverviewOutput {
  ErkeOverviewOutput({
    required this.totalScore,
    required List<ErkeCategorySkillSummary> categories,
    required List<ErkeActivitySkillSummary> recentActivities,
    required this.activityCount,
    required this.dataUpdatedAt,
  })  : categories = List<ErkeCategorySkillSummary>.unmodifiable(categories),
        recentActivities =
            List<ErkeActivitySkillSummary>.unmodifiable(recentActivities);

  final double? totalScore;
  final List<ErkeCategorySkillSummary> categories;
  final List<ErkeActivitySkillSummary> recentActivities;
  final int activityCount;
  final DateTime? dataUpdatedAt;
}

class ErkeOverviewSkill
    implements PersonalSkill<ErkeOverviewInput, ErkeOverviewOutput> {
  static const String skillId = 'personal.erke.overview';
  static const int _maximumCategories = 20;
  static const int _maximumActivities = 5;

  @override
  String get id => skillId;

  @override
  SkillSensitivity get sensitivity => SkillSensitivity.medium;

  @override
  Set<PersonalDataType> get requiredDataTypes =>
      const <PersonalDataType>{PersonalDataType.erke};

  @override
  Future<SkillResult<ErkeOverviewOutput>> execute(
    ErkeOverviewInput input,
    SkillExecutionContext context,
  ) async {
    final gateway = await context.getErkeOverview();
    final failure = gatewayFailure<ErkeOverviewOutput, ErkeOverview>(
      gateway,
      dataLabel: '二课',
    );
    if (failure != null) return failure;

    final overview = gateway.data!;
    final categories = overview.categories.take(_maximumCategories).map(
          (category) => ErkeCategorySkillSummary(
            code: category.code,
            name: category.name,
            required: category.required,
            earned: category.earned,
            meetsNumerically: category.meetsNumerically,
          ),
        );
    final activities = overview.recentActivities.take(_maximumActivities).map(
          (activity) => ErkeActivitySkillSummary(
            item: activity.item,
            score: activity.score,
            date: activity.date,
            category: activity.category,
          ),
        );
    final truncated = overview.categories.length > _maximumCategories ||
        overview.recentActivities.length > _maximumActivities;
    return SkillResult<ErkeOverviewOutput>(
      value: ErkeOverviewOutput(
        totalScore: overview.earnedTotal,
        categories: categories.toList(growable: false),
        recentActivities: activities.toList(growable: false),
        activityCount: overview.activityCount,
        dataUpdatedAt: gateway.fetchedAt,
      ),
      status: truncated ? SkillStatus.partial : SkillStatus.success,
      evidence: <SkillEvidence>[
        gatewayEvidence(
          gateway,
          dataType: PersonalDataType.erke,
          scope: '二课总分、分类与最近活动概览',
        ),
      ],
      warnings: mergeWarnings(
        gateway.warnings,
        <String>[if (truncated) '二课概览超过输出上限，已截断'],
      ),
      containsPersonalData: true,
    );
  }
}
