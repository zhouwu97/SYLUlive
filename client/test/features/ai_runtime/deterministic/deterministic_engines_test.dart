import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/ai_runtime/deterministic/academic_calculation_engine.dart';
import 'package:shenliyuan/features/ai_runtime/deterministic/competition_fit_engine.dart';
import 'package:shenliyuan/features/ai_runtime/deterministic/fitness_weekly_plan_engine.dart';
import 'package:shenliyuan/features/ai_runtime/deterministic/graduation_requirement_engine.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/models/academic_records.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/models/erke_overview.dart';

void main() {
  group('AcademicCalculationEngine', () {
    final engine = AcademicCalculationEngine();

    test('GPA 固定公式包含纳入排除证据并选取重修最佳成绩', () {
      final result = engine.calculateGpa(<CourseGradeRecord>[
        _course('math', score: 55, credit: 4),
        _course(
          'math',
          score: 85,
          credit: 4,
          attempt: CourseAttemptType.retake,
          semester: '2025_2',
        ),
        _course('english', gradeText: '良好', credit: 2),
        _course('missing-credit', score: 90, credit: 0),
        _course('unknown', gradeText: '缓考', credit: 1),
      ]);

      expect(result.formulaVersion, AcademicCalculationEngine.formulaVersion);
      expect(result.gpa, closeTo(3.7, 0.001));
      expect(result.includedCourses, hasLength(2));
      expect(result.excludedCourses, hasLength(2));
      expect(result.unparseableCourses, <String>['unknown']);
      expect(result.missingCreditCount, 1);
    });

    test('学分和挂科对未知、必修、补考进行确定性分类', () {
      final courses = <CourseGradeRecord>[
        _course('pass', score: 80, credit: 3),
        _course(
          'fail',
          score: 50,
          credit: 2,
          nature: CourseNature.requiredCourse,
        ),
        _course('pending', gradeText: '缓考', credit: 1),
      ];
      final credits = engine.calculateCredits(courses);
      final failures = engine.calculateFailures(courses);
      expect(credits.passedCredits, 3);
      expect(credits.failedCredits, 2);
      expect(credits.requiredFailedCredits, 2);
      expect(credits.unknownCredits, 1);
      expect(failures.failedCourses.single.courseId, 'fail');
      expect(failures.unknownCourses.single.courseId, 'pending');
    });

    test('缺少有效课程时 GPA 返回 null 而不是 0', () {
      final result = engine.calculateGpa(<CourseGradeRecord>[
        _course('pending', gradeText: '--', credit: 2),
      ]);
      expect(result.gpa, isNull);
    });
  });

  group('GraduationRequirementEngine', () {
    test('没有人工审核规则时状态为 blocked', () {
      final result = GraduationRequirementEngine().evaluate(
        academic: AcademicRecords(courses: const <CourseGradeRecord>[]),
        erke: _erke(earned: 20),
        rules: null,
      );
      expect(result.items.single.state, RequirementState.blocked);
    });

    test('五态清单区分未完成、未知和阻断', () {
      final result = GraduationRequirementEngine().evaluate(
        academic: AcademicRecords(courses: <CourseGradeRecord>[
          _course(
            'required',
            score: 50,
            credit: 3,
            nature: CourseNature.requiredCourse,
          ),
          _course('pending', gradeText: '缓考', credit: 2),
        ]),
        erke: _erke(earned: 25),
        rules: _rules(),
      );
      expect(
        result.items.firstWhere((item) => item.id == 'total_credits').state,
        RequirementState.unknown,
      );
      expect(
        result.items.firstWhere((item) => item.id == 'required_courses').state,
        RequirementState.notCompleted,
      );
      expect(
        result.items.firstWhere((item) => item.id == 'erke').state,
        RequirementState.completed,
      );
      expect(
        result.items.firstWhere((item) => item.id == 'practice').state,
        RequirementState.blocked,
      );
    });
  });

  group('CompetitionFitEngine', () {
    const profile = StudentCompetitionProfile(
      grade: '2024',
      college: '信息科学与工程学院',
      major: '计算机科学与技术',
      goals: <String>['人工智能'],
    );

    test('硬资格不匹配首先阻断', () {
      final result = CompetitionFitEngine().rank(
        const <CompetitionCandidate>[
          CompetitionCandidate(
            id: '1',
            title: '仅 2023 级',
            eligibleGrades: <String>['2023'],
            strongRecommendationReady: true,
            evidenceStatus: 'verified',
          ),
        ],
        profile,
      ).single;
      expect(result.status, CompetitionFitStatus.notEligible);
      expect(result.strongRecommendationAllowed, isFalse);
    });

    test('空资格数组表示不限且允许通过资格判断', () {
      final result = CompetitionFitEngine().rank(
        const <CompetitionCandidate>[
          CompetitionCandidate(
            id: '1',
            title: '不限年级学院专业的竞赛',
            eligibleGrades: <String>[],
            eligibleColleges: <String>[],
            eligibleMajors: <String>[],
            evidenceStatus: 'verified',
            strongRecommendationReady: true,
          ),
        ],
        profile,
      ).single;

      expect(result.status, CompetitionFitStatus.eligible);
      expect(result.strongRecommendationAllowed, isTrue);
    });

    test('非空资格限制但用户属性缺失时保留未知态', () {
      const incompleteProfile = StudentCompetitionProfile(
        grade: '',
        college: '信息科学与工程学院',
        major: '计算机科学与技术',
      );
      final result = CompetitionFitEngine().rank(
        const <CompetitionCandidate>[
          CompetitionCandidate(
            id: '1',
            title: '限定年级的竞赛',
            eligibleGrades: <String>['2024'],
            evidenceStatus: 'verified',
            strongRecommendationReady: true,
          ),
        ],
        incompleteProfile,
      ).single;

      expect(result.status, CompetitionFitStatus.eligibilityUnknown);
      expect(result.strongRecommendationAllowed, isFalse);
    });

    test('strong_recommendation_ready=false 时禁止强推荐', () {
      final result = CompetitionFitEngine().rank(
        const <CompetitionCandidate>[
          CompetitionCandidate(
            id: '1',
            title: 'AI 竞赛',
            eligibleGrades: <String>['2024'],
            eligibleColleges: <String>['信息科学与工程学院'],
            eligibleMajors: <String>['计算机科学与技术'],
            evidenceStatus: 'verified',
            strongRecommendationReady: false,
          ),
        ],
        profile,
      ).single;
      expect(result.status, CompetitionFitStatus.possiblySuitable);
      expect(result.strongRecommendationAllowed, isFalse);
    });
  });

  group('FitnessWeeklyPlanEngine', () {
    test('计算 BMI，最多三次且训练间隔至少 20 小时', () {
      final start = DateTime.utc(2026, 7, 20, 18);
      final plan = FitnessWeeklyPlanEngine().build(
        heightMeters: 1.75,
        weightKg: 70,
        physicalOverviewAvailable: true,
        freeWindows: List<FitnessTimeWindow>.generate(
          7,
          (index) => FitnessTimeWindow(
            start: start.add(Duration(days: index)),
            end: start.add(Duration(days: index, hours: 1)),
          ),
        ),
      );
      expect(plan.bmi, closeTo(22.86, 0.01));
      expect(plan.sessions, hasLength(3));
      expect(plan.sessions.every((item) => item.minutes <= 60), isTrue);
    });

    test('缺少体测或报告不适时只给轻强度并包含安全提示', () {
      final plan = FitnessWeeklyPlanEngine().build(
        freeWindows: <FitnessTimeWindow>[
          FitnessTimeWindow(
            start: DateTime.utc(2026, 7, 20, 18),
            end: DateTime.utc(2026, 7, 20, 19),
          ),
        ],
        reportsDiscomfort: true,
      );
      expect(plan.sessions.single.intensity, FitnessIntensity.light);
      expect(plan.safetyNotes.join(), contains('不是医疗诊断'));
      expect(plan.bmi, isNull);
    });
  });
}

CourseGradeRecord _course(
  String id, {
  double? score,
  String? gradeText,
  required double credit,
  CourseNature nature = CourseNature.other,
  CourseAttemptType attempt = CourseAttemptType.normal,
  String semester = '2025_1',
}) =>
    CourseGradeRecord(
      courseId: id,
      courseName: id,
      score: score,
      gradeText: gradeText,
      credit: credit,
      nature: nature,
      attemptType: attempt,
      semesterId: semester,
    );

ErkeOverview _erke({required double earned}) => ErkeOverview(
      activityCount: 0,
      categories: const <ErkeCategoryOverview>[],
      earnedTotal: earned,
      requiredTotal: 20,
    );

CurriculumRulePackage _rules() => CurriculumRulePackage(
      policyId: 'sylu-2024-cs',
      effectiveFrom: DateTime.utc(2024, 9, 1),
      college: '信息科学与工程学院',
      major: '计算机科学与技术',
      grade: '2024',
      requiredTotalCredits: 165,
      requiredErkeScore: 20,
      sourceDocument: '2024 级培养方案',
      publishedAt: DateTime.utc(2024, 6, 1),
      humanReviewed: true,
    );
