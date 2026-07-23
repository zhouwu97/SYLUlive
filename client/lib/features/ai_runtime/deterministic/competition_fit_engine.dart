enum CompetitionFitStatus {
  eligible,
  possiblySuitable,
  needsConfirmation,
  eligibilityUnknown,
  notEligible,
}

class CompetitionCandidate {
  const CompetitionCandidate({
    required this.id,
    required this.title,
    this.eligibleGrades = const <String>[],
    this.eligibleColleges = const <String>[],
    this.eligibleMajors = const <String>[],
    this.schoolRecognitionStatus = '',
    this.schoolRecognitionGrade = '',
    this.importanceScore = 0,
    this.manualRating,
    this.evidenceStatus = '',
    this.strongRecommendationReady = false,
    this.registrationOpen = false,
    this.tags = const <String>[],
  });
  final String id;
  final String title;
  final List<String> eligibleGrades;
  final List<String> eligibleColleges;
  final List<String> eligibleMajors;
  final String schoolRecognitionStatus;
  final String schoolRecognitionGrade;
  final int importanceScore;
  final double? manualRating;
  final String evidenceStatus;
  final bool strongRecommendationReady;
  final bool registrationOpen;
  final List<String> tags;
}

class StudentCompetitionProfile {
  const StudentCompetitionProfile({
    required this.grade,
    required this.college,
    required this.major,
    this.goals = const <String>[],
  });
  final String grade;
  final String college;
  final String major;
  final List<String> goals;
}

class CompetitionFitResult {
  CompetitionFitResult({
    required this.candidate,
    required this.status,
    required this.score,
    required this.strongRecommendationAllowed,
    required List<String> reasons,
  }) : reasons = List.unmodifiable(reasons);
  final CompetitionCandidate candidate;
  final CompetitionFitStatus status;
  final int score;
  final bool strongRecommendationAllowed;
  final List<String> reasons;
}

class CompetitionFitEngine {
  List<CompetitionFitResult> rank(
    List<CompetitionCandidate> candidates,
    StudentCompetitionProfile profile,
  ) {
    final results =
        candidates.map((candidate) => _evaluate(candidate, profile)).toList();
    results.sort((left, right) => right.score.compareTo(left.score));
    return List.unmodifiable(results);
  }

  CompetitionFitResult _evaluate(
    CompetitionCandidate candidate,
    StudentCompetitionProfile profile,
  ) {
    final reasons = <String>[];
    final eligibility = <bool?>[
      _matches(candidate.eligibleGrades, profile.grade),
      _matches(candidate.eligibleColleges, profile.college),
      _matches(candidate.eligibleMajors, profile.major),
    ];
    if (eligibility.contains(false)) {
      return CompetitionFitResult(
        candidate: candidate,
        status: CompetitionFitStatus.notEligible,
        score: 0,
        strongRecommendationAllowed: false,
        reasons: const <String>['不满足已知年级、学院或专业硬资格'],
      );
    }
    var score = candidate.importanceScore.clamp(0, 100);
    if (candidate.schoolRecognitionStatus.contains('认定')) {
      score += 20;
      reasons.add('有学校认定信息');
    }
    if (candidate.registrationOpen) {
      score += 10;
      reasons.add('当前可报名');
    }
    final goalMatches = candidate.tags
        .where((tag) => profile.goals
            .any((goal) => goal.contains(tag) || tag.contains(goal)))
        .length;
    score += goalMatches * 5;
    final unknown = eligibility.contains(null);
    final strongAllowed = candidate.strongRecommendationReady &&
        candidate.evidenceStatus == 'verified' &&
        !unknown;
    if (!strongAllowed) reasons.add('证据或强推荐门槛未满足');
    return CompetitionFitResult(
      candidate: candidate,
      status: unknown
          ? CompetitionFitStatus.eligibilityUnknown
          : strongAllowed
              ? CompetitionFitStatus.eligible
              : CompetitionFitStatus.possiblySuitable,
      score: score.clamp(0, 150),
      strongRecommendationAllowed: strongAllowed,
      reasons: reasons,
    );
  }

  bool? _matches(List<String> allowed, String actual) {
    if (allowed.isEmpty) return true;
    if (actual.trim().isEmpty) return null;
    return allowed.any((item) => item == actual || item == '全部');
  }
}
