/// 二课系统内网路径常量 (通过 WebVPN 代理访问)
class ErkeEndpoints {
  ErkeEndpoints._();

  /// 二课登录页
  static const String login = '/SyluTW/Sys/UserLogin.aspx';

  /// 活动查询页（明细列表）
  static const String activitySearch =
      '/SyluTW/Sys/SystemForm/StuAction/StuActionSearch.aspx';

  /// 第二课堂成绩审查 — 毕业要求汇总
  static const String graduationSummary =
      '/SyluTW/Sys/SystemForm/FinishExam/StuFinishStudentScore.aspx';

  /// 第二课堂学年成绩审查 — 学年要求汇总
  static const String yearlySummary =
      '/SyluTW/Sys/SystemForm/FinishExam/StuFinishStudentScoreXN.aspx';
}
