enum AiQuickPromptFeature {
  policy,
  schedule,
  competitionCompare,
  academicAnalysis,
  weekPlan,
}

class AiQuickPrompt {
  final String category;
  final String question;
  final AiQuickPromptFeature feature;

  const AiQuickPrompt({
    required this.category,
    required this.question,
    required this.feature,
  });
}
