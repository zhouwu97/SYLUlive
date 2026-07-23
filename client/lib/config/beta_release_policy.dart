/// Beta-0 内测功能边界。
///
/// 未完成能力通过编译期策略关闭，保留代码和后续恢复入口，但不能被本地偏好
/// 或历史缓存重新开启。正式放开某项能力前，必须先完成对应阶段验收。
abstract final class BetaReleasePolicy {
  static const String releaseName = '沈理校园 内测版 · 学业总览 Beta';

  static const bool graduationWarningResults = false;
  static const bool aiGraduationAssistant = false;
  static const bool aiCompetitionFit = false;
  static const bool aiTeamMatching = false;
  static const bool competitionRecommendations = false;
  static const bool awardArchive = false;
  static const bool policyBenefits = false;
  static const bool clientAcademicProbe = false;
}
