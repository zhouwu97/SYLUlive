import 'academic_overview_skill.dart';
import 'competition_search_skill.dart';
import 'erke_overview_skill.dart';
import 'personal_skill.dart';
import 'personal_skill_registry.dart';
import 'physical_overview_skill.dart';
import 'today_schedule_skill.dart';
import 'week_schedule_skill.dart';

/// 阶段五固定允许列表。新增能力必须显式修改此处并补充边界测试。
PersonalSkillRegistry buildStageFiveSkillRegistry({
  required CompetitionSearchSource competitionSearchSource,
}) {
  return PersonalSkillRegistry(<PersonalSkill<dynamic, dynamic>>[
    TodayScheduleSkill(),
    WeekScheduleSkill(),
    AcademicOverviewSkill(),
    PhysicalOverviewSkill(),
    ErkeOverviewSkill(),
    CompetitionSearchSkill(competitionSearchSource),
  ]);
}
