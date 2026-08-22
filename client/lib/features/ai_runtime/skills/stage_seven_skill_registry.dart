import 'competition_search_skill.dart';
import 'competition_advisor_skills.dart';
import 'deterministic_skills.dart';
import 'personal_skill.dart';
import 'personal_skill_registry.dart';
import 'academic_overview_skill.dart';
import 'erke_overview_skill.dart';
import 'physical_overview_skill.dart';
import 'today_schedule_skill.dart';
import 'week_schedule_skill.dart';
import 'competition_plan_action_skill.dart';
import 'calendar_action_skill.dart';

PersonalSkillRegistry buildStageSevenSkillRegistry({
  required CompetitionSearchSource competitionSearchSource,
  required GraduationRuleProvider graduationRuleProvider,
  required CompetitionCapabilityProfileSource
      competitionCapabilityProfileSource,
  required CompetitionMatchExplanationSource competitionMatchExplanationSource,
  required CompetitionPlanActionSource competitionPlanActionSource,
  CalendarActionSource? calendarActionSource,
}) {
  final skills = <PersonalSkill<dynamic, dynamic>>[
    TodayScheduleSkill(),
    WeekScheduleSkill(),
    AcademicOverviewSkill(),
    PhysicalOverviewSkill(),
    ErkeOverviewSkill(),
    CompetitionSearchSkill(competitionSearchSource),
    CompetitionCapabilityProfileSkill(competitionCapabilityProfileSource),
    ExplainCompetitionMatchesSkill(competitionMatchExplanationSource),
    DraftAddCompetitionToPlanSkill(competitionPlanActionSource),
    AcademicGpaSkill(),
    AcademicCreditSummarySkill(),
    AcademicFailureRiskSkill(),
    GraduationReadinessSkill(ruleProvider: graduationRuleProvider),
    FitnessWeeklyPlanSkill(),
    if (calendarActionSource != null) CalendarActionSkill(calendarActionSource),
  ];
  return PersonalSkillRegistry(skills);
}
