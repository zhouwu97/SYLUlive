import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/gateway/gateway_result.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/gateway/personal_data_gateway.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/models/academic_overview.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/models/academic_records.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/models/erke_overview.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/models/physical_overview.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/models/schedule_overview.dart';
import 'package:shenliyuan/features/ai_runtime/deterministic/competition_fit_engine.dart';
import 'package:shenliyuan/features/ai_runtime/skills/deterministic_skills.dart';
import 'package:shenliyuan/features/ai_runtime/skills/personal_skills.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';
import 'package:shenliyuan/models/competition.dart';

void main() {
  final fetchedAt = DateTime.utc(2026, 7, 20, 8, 30);
  late _FakeGateway gateway;
  late _FakeCompetitionSource competitions;
  late SkillExecutionContext context;

  setUp(() {
    gateway = _FakeGateway();
    competitions = _FakeCompetitionSource();
    context = SkillExecutionContext(
      personalDataGateway: gateway,
      clock: () => DateTime.utc(2026, 7, 20, 9),
    );
  });

  group('固定注册表', () {
    test('只注册阶段五六个允许的 Skill', () {
      final registry = buildStageFiveSkillRegistry(
        competitionSearchSource: competitions,
      );

      expect(
        registry.registeredSkillIds,
        <String>{
          TodayScheduleSkill.skillId,
          WeekScheduleSkill.skillId,
          AcademicOverviewSkill.skillId,
          PhysicalOverviewSkill.skillId,
          ErkeOverviewSkill.skillId,
          CompetitionSearchSkill.skillId,
        },
      );
    });

    test('未知 Skill ID 和错误输入类型均失败关闭', () async {
      final registry = buildStageFiveSkillRegistry(
        competitionSearchSource: competitions,
      );

      final unknown = await registry.execute(
        id: 'personal.unknown.read_all',
        input: const AcademicOverviewInput(),
        context: context,
      );
      final wrongInput = await registry.execute(
        id: TodayScheduleSkill.skillId,
        input: const AcademicOverviewInput(),
        context: context,
      );

      expect(unknown.status, SkillStatus.unknownSkill);
      expect(wrongInput.status, SkillStatus.invalidInput);
      expect(gateway.totalReads, 0);
    });

    test('Skill 读取未声明的数据类型时被拒绝', () async {
      final registry = PersonalSkillRegistry(
        <PersonalSkill<dynamic, dynamic>>[_UndeclaredAccessSkill()],
      );

      final result = await registry.execute(
        id: _UndeclaredAccessSkill.skillId,
        input: const _EmptyInput(),
        context: context,
      );

      expect(result.status, SkillStatus.denied);
      expect(gateway.physicalReads, 0);
    });

    test('成功结果缺少来源时间证据时失败关闭', () async {
      final registry = PersonalSkillRegistry(
        <PersonalSkill<dynamic, dynamic>>[_MissingEvidenceSkill()],
      );

      final result = await registry.execute(
        id: _MissingEvidenceSkill.skillId,
        input: const _EmptyInput(),
        context: context,
      );

      expect(result.status, SkillStatus.failed);
      expect(result.value, isNull);
    });
  });

  test('今日课表只读当日课程并生成时间与空闲区间', () async {
    final date = DateTime.utc(2026, 7, 20);
    gateway.schedule = _available(
      ScheduleOverview(
        start: date,
        end: date,
        availableSemesterIds: const <String>['2026_1'],
        occurrences: <ScheduleCourseOccurrence>[
          ScheduleCourseOccurrence(
            date: date,
            semesterId: '2026_1',
            courseName: '数据结构',
            weekday: 1,
            startSection: 3,
            endSection: 4,
            location: '主楼 101',
          ),
        ],
        termsWithoutStartDate: 0,
      ),
      fetchedAt: fetchedAt,
    );

    final result = await TodayScheduleSkill().execute(
      TodayScheduleInput(date: date),
      context.restrictTo(const <PersonalDataType>{PersonalDataType.schedule}),
    );

    expect(result.status, SkillStatus.success);
    expect(result.value?.courses.single.courseName, '数据结构');
    expect(result.value?.courses.single.timeText, '10:00-11:40');
    expect(result.value?.freeTimeSlots.first.timeText, '08:00-09:40');
    expect(result.value?.freeTimeSlots.last.timeText, '13:00-20:10');
    expect(result.value?.dataUpdatedAt, fetchedAt);
    expect(result.evidence.single.source, 'local_encrypted_vault');
    expect(result.evidence.single.dataType, PersonalDataType.schedule);
    expect(result.containsPersonalData, isTrue);
    expect(gateway.scheduleReads, 1);
    expect(gateway.totalReads, 1);
  });

  test('本周课表拒绝超过七天的范围且不触发 Gateway', () async {
    final result = await WeekScheduleSkill().execute(
      WeekScheduleInput(
        start: DateTime.utc(2026, 7, 1),
        end: DateTime.utc(2026, 7, 8),
      ),
      context.restrictTo(const <PersonalDataType>{PersonalDataType.schedule}),
    );

    expect(result.status, SkillStatus.invalidInput);
    expect(gateway.totalReads, 0);
  });

  test('本周课表默认只请求锚点所在自然周', () async {
    gateway.schedule = _available(
      ScheduleOverview(
        start: DateTime.utc(2026, 7, 20),
        end: DateTime.utc(2026, 7, 26),
        availableSemesterIds: const <String>[],
        occurrences: const <ScheduleCourseOccurrence>[],
        termsWithoutStartDate: 0,
      ),
      fetchedAt: fetchedAt,
    );

    final result = await WeekScheduleSkill().execute(
      WeekScheduleInput.containing(DateTime.utc(2026, 7, 22)),
      context.restrictTo(const <PersonalDataType>{PersonalDataType.schedule}),
    );

    expect(result.status, SkillStatus.success);
    expect(gateway.lastScheduleStart, DateTime.utc(2026, 7, 20));
    expect(gateway.lastScheduleEnd, DateTime.utc(2026, 7, 26));
  });

  test('学业概览仅返回课程数量、覆盖学期和缺失标记', () async {
    gateway.academic = _available(
      AcademicOverview(
        terms: <AcademicTermOverview>[
          AcademicTermOverview(
            year: '2025',
            semester: 3,
            courseCount: 8,
            fetchedAt: fetchedAt,
          ),
        ],
        totalRecordedCourses: 8,
        hasAcademicSituation: false,
      ),
      fetchedAt: fetchedAt,
    );

    final result = await AcademicOverviewSkill().execute(
      const AcademicOverviewInput(),
      context.restrictTo(const <PersonalDataType>{PersonalDataType.academic}),
    );

    expect(result.status, SkillStatus.partial);
    expect(result.value?.acquiredCourseCount, 8);
    expect(result.value?.coveredTerms.single.year, '2025');
    expect(result.value?.hasMissingData, isTrue);
    expect(result.warnings, contains('原始学业情况概览缺失'));
    expect(gateway.academicReads, 1);
    expect(gateway.totalReads, 1);
  });

  test('Gateway 缺少成绩数据时返回明确 missingData', () async {
    gateway.academic = GatewayResult<AcademicOverview>(
      status: GatewayStatus.missing,
      source: PersonalDataSource.none,
    );

    final result = await AcademicOverviewSkill().execute(
      const AcademicOverviewInput(),
      context.restrictTo(const <PersonalDataType>{PersonalDataType.academic}),
    );

    expect(result.status, SkillStatus.missingData);
    expect(result.value, isNull);
    expect(result.containsPersonalData, isFalse);
  });

  test('体测概览返回最近学年项目并只判断 BMI 原始输入可用性', () async {
    gateway.physical = _available(
      const PhysicalOverview(
        latestYear: '2026',
        availableYears: <String>['2026', '2025'],
        totalGrade: '良好',
        totalScore: 88,
        metrics: <PhysicalMetricOverview>[
          PhysicalMetricOverview(
            name: '身高',
            result: '175',
            grade: '',
            score: null,
          ),
          PhysicalMetricOverview(
            name: '体重',
            result: '65',
            grade: '',
            score: null,
          ),
        ],
      ),
      fetchedAt: fetchedAt,
    );

    final result = await PhysicalOverviewSkill().execute(
      const PhysicalOverviewInput(),
      context.restrictTo(const <PersonalDataType>{PersonalDataType.physical}),
    );

    expect(result.status, SkillStatus.success);
    expect(result.value?.latestYear, '2026');
    expect(result.value?.bmiInputsAvailable, isTrue);
    expect(result.value?.metrics, hasLength(2));
    expect(gateway.totalReads, 1);
  });

  test('二课概览返回总分、分类和最多五条最近活动', () async {
    gateway.erke = _available(
      ErkeOverview(
        earnedTotal: 18,
        activityCount: 6,
        categories: const <ErkeCategoryOverview>[
          ErkeCategoryOverview(
            code: 'A',
            name: '思想成长',
            required: 4,
            earned: 5,
            meetsNumerically: true,
          ),
        ],
        recentActivities: List<ErkeActivityOverview>.generate(
          6,
          (index) => ErkeActivityOverview(
            item: '活动 $index',
            score: 1,
            date: '2026-07-${20 - index}',
            category: 'A',
          ),
        ),
      ),
      fetchedAt: fetchedAt,
    );

    final result = await ErkeOverviewSkill().execute(
      const ErkeOverviewInput(),
      context.restrictTo(const <PersonalDataType>{PersonalDataType.erke}),
    );

    expect(result.status, SkillStatus.partial);
    expect(result.value?.totalScore, 18);
    expect(result.value?.categories.single.name, '思想成长');
    expect(result.value?.recentActivities, hasLength(5));
    expect(gateway.totalReads, 1);
  });

  test('过期个人数据保留输出并携带过期证据', () async {
    gateway.physical = GatewayResult<PhysicalOverview>(
      data: const PhysicalOverview(
        latestYear: '2026',
        availableYears: <String>['2026'],
        totalGrade: '合格',
        totalScore: 80,
        metrics: <PhysicalMetricOverview>[],
      ),
      status: GatewayStatus.stale,
      source: PersonalDataSource.localEncryptedVault,
      fetchedAt: fetchedAt,
      expiresAt: fetchedAt.add(const Duration(days: 7)),
      isStale: true,
      warnings: const <String>['体测数据已过期，建议先同步'],
    );

    final result = await PhysicalOverviewSkill().execute(
      const PhysicalOverviewInput(),
      context.restrictTo(const <PersonalDataType>{PersonalDataType.physical}),
    );

    expect(result.status, SkillStatus.success);
    expect(result.evidence.single.isStale, isTrue);
    expect(result.warnings, isNotEmpty);
  });

  test('公开竞赛检索不读取个人 Gateway 且结果标记为非个人数据', () async {
    competitions.page = CompetitionSearchPage(
      events: <CompetitionEvent>[
        CompetitionEvent(
          id: 7,
          title: '大学生程序设计竞赛',
          summary: '公开赛事',
          schoolRecognitionStatus: 'recognized',
          registrationTimeText: '2026-09',
          officialUrl: 'https://example.test/competition/7',
          tags: const <String>['程序设计'],
        ),
      ],
      total: 1,
      fetchedAt: fetchedAt,
    );

    final result = await CompetitionSearchSkill(competitions).execute(
      const CompetitionSearchInput(keyword: '  程序设计  ', limit: 10),
      context.restrictTo(const <PersonalDataType>{}),
    );

    expect(result.status, SkillStatus.success);
    expect(result.value?.keyword, '程序设计');
    expect(result.value?.items.single.title, '大学生程序设计竞赛');
    expect(result.evidence.single.source, 'campus_competition_api');
    expect(result.containsPersonalData, isFalse);
    expect(competitions.lastInput?.keyword, '程序设计');
    expect(gateway.totalReads, 0);
  });

  test('公开竞赛检索拒绝空关键词和超过二十条的请求', () async {
    final skill = CompetitionSearchSkill(competitions);
    final empty = await skill.execute(
      const CompetitionSearchInput(keyword: ''),
      context.restrictTo(const <PersonalDataType>{}),
    );
    final tooMany = await skill.execute(
      const CompetitionSearchInput(keyword: '竞赛', limit: 21),
      context.restrictTo(const <PersonalDataType>{}),
    );

    expect(empty.status, SkillStatus.invalidInput);
    expect(tooMany.status, SkillStatus.invalidInput);
    expect(competitions.calls, 0);
  });

  test('公开竞赛数据源只请求公开目录并限制分页大小', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          expect(options.path, '/competitions/events');
          expect(options.queryParameters['keyword'], '算法');
          expect(options.queryParameters['page'], 1);
          expect(options.queryParameters['page_size'], 3);
          expect(options.queryParameters, isNot(contains('user_id')));
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'total': 1,
                'items': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 9,
                    'title': '算法设计竞赛',
                    'summary': '公开赛事',
                  },
                ],
              },
            ),
          );
        },
      ),
    );

    final page = await DioCompetitionSearchSource(
      dio,
      clock: () => fetchedAt,
    ).search(const CompetitionSearchInput(keyword: '算法', limit: 3));

    expect(page.events.single.title, '算法设计竞赛');
    expect(page.total, 1);
    expect(page.fetchedAt, fetchedAt);
  });

  test('竞赛适配只读取基础画像且无成绩缓存时仍可运行', () async {
    final source = _FakeCompetitionFitSource(
      candidatesValue: const <CompetitionCandidate>[
        CompetitionCandidate(
          id: 'ai',
          title: '人工智能竞赛',
          tags: <String>['人工智能'],
          importanceScore: 60,
        ),
      ],
      profileValue: const StudentCompetitionProfile(
        grade: '2024',
        college: '信息科学与工程学院',
        major: '计算机科学与技术',
      ),
    );
    final skill = CompetitionFitSkill(source);

    final result = await skill.execute(
      const CompetitionFitInput(goals: <String>['人工智能']),
      context.restrictTo(
        const <PersonalDataType>{PersonalDataType.studentProfile},
      ),
    );

    expect(skill.requiredDataTypes,
        const <PersonalDataType>{PersonalDataType.studentProfile});
    expect(result.status, SkillStatus.success);
    expect(result.containsPersonalData, isTrue);
    expect(result.value?.items.single.score, 65);
    expect(result.evidence.single.source, '本地教务绑定资料');
    expect(result.evidence.single.scope, '年级、学院、专业和本次竞赛目标');
    expect(result.evidence.single.dataType, PersonalDataType.studentProfile);
    expect(gateway.academicRecordReads, 0);
    expect(gateway.totalReads, 0);
  });

  test('竞赛适配空目标仍按资格和报名状态排序', () async {
    final source = _FakeCompetitionFitSource(
      candidatesValue: const <CompetitionCandidate>[
        CompetitionCandidate(
          id: 'open',
          title: '开放报名竞赛',
          importanceScore: 40,
          registrationOpen: true,
          schoolRecognitionStatus: '学校认定',
        ),
      ],
      profileValue: const StudentCompetitionProfile(
        grade: '2024',
        college: '信息科学与工程学院',
        major: '计算机科学与技术',
      ),
    );

    final result = await CompetitionFitSkill(source).execute(
      const CompetitionFitInput(),
      context.restrictTo(
        const <PersonalDataType>{PersonalDataType.studentProfile},
      ),
    );

    expect(result.status, SkillStatus.success);
    expect(result.value?.items.single.score, 70);
    expect(gateway.totalReads, 0);
  });
}

GatewayResult<T> _available<T>(T data, {required DateTime fetchedAt}) =>
    GatewayResult<T>(
      data: data,
      status: GatewayStatus.available,
      source: PersonalDataSource.localEncryptedVault,
      fetchedAt: fetchedAt,
    );

class _FakeGateway implements PersonalDataGateway {
  GatewayResult<ErkeOverview> erke = GatewayResult<ErkeOverview>(
    status: GatewayStatus.missing,
    source: PersonalDataSource.none,
  );
  GatewayResult<PhysicalOverview> physical = GatewayResult<PhysicalOverview>(
    status: GatewayStatus.missing,
    source: PersonalDataSource.none,
  );
  GatewayResult<ScheduleOverview> schedule = GatewayResult<ScheduleOverview>(
    status: GatewayStatus.missing,
    source: PersonalDataSource.none,
  );
  GatewayResult<AcademicOverview> academic = GatewayResult<AcademicOverview>(
    status: GatewayStatus.missing,
    source: PersonalDataSource.none,
  );

  int erkeReads = 0;
  int physicalReads = 0;
  int scheduleReads = 0;
  int academicReads = 0;
  int academicRecordReads = 0;
  DateTime? lastScheduleStart;
  DateTime? lastScheduleEnd;

  int get totalReads =>
      erkeReads +
      physicalReads +
      scheduleReads +
      academicReads +
      academicRecordReads;

  @override
  Future<void> close() async {}

  @override
  Future<GatewayResult<AcademicOverview>> getAcademicOverview() async {
    academicReads++;
    return academic;
  }

  @override
  Future<GatewayResult<AcademicRecords>> getAcademicRecords() async {
    academicRecordReads++;
    return GatewayResult<AcademicRecords>(
      status: GatewayStatus.missing,
      source: PersonalDataSource.none,
    );
  }

  @override
  Future<GatewayResult<ErkeOverview>> getErkeOverview() async {
    erkeReads++;
    return erke;
  }

  @override
  Future<GatewayResult<PhysicalOverview>> getPhysicalOverview() async {
    physicalReads++;
    return physical;
  }

  @override
  Future<GatewayResult<ScheduleOverview>> getScheduleOverview({
    required DateTime start,
    required DateTime end,
  }) async {
    scheduleReads++;
    lastScheduleStart = start;
    lastScheduleEnd = end;
    return schedule;
  }
}

class _FakeCompetitionSource implements CompetitionSearchSource {
  CompetitionSearchPage? page;
  CompetitionSearchInput? lastInput;
  int calls = 0;

  @override
  Future<CompetitionSearchPage> search(CompetitionSearchInput input) async {
    calls++;
    lastInput = input;
    return page ??
        CompetitionSearchPage(
          events: const <CompetitionEvent>[],
          total: 0,
          fetchedAt: DateTime.utc(2026, 7, 20),
        );
  }
}

class _FakeCompetitionFitSource implements CompetitionFitDataSource {
  _FakeCompetitionFitSource({
    required this.candidatesValue,
    required this.profileValue,
  });

  final List<CompetitionCandidate> candidatesValue;
  final StudentCompetitionProfile profileValue;
  int candidateReads = 0;
  int profileReads = 0;

  @override
  Future<List<CompetitionCandidate>> candidates() async {
    candidateReads++;
    return candidatesValue;
  }

  @override
  Future<StudentCompetitionProfile> currentProfile() async {
    profileReads++;
    return profileValue;
  }
}

class _EmptyInput {
  const _EmptyInput();
}

class _UndeclaredAccessSkill implements PersonalSkill<_EmptyInput, Object?> {
  static const String skillId = 'test.undeclared';

  @override
  String get id => skillId;

  @override
  Set<PersonalDataType> get requiredDataTypes =>
      const <PersonalDataType>{PersonalDataType.erke};

  @override
  SkillSensitivity get sensitivity => SkillSensitivity.medium;

  @override
  Future<SkillResult<Object?>> execute(
    _EmptyInput input,
    SkillExecutionContext context,
  ) async {
    await context.restrictTo(const <PersonalDataType>{
      PersonalDataType.physical
    }).getPhysicalOverview();
    return SkillResult<Object?>(
      status: SkillStatus.success,
      containsPersonalData: true,
    );
  }
}

class _MissingEvidenceSkill implements PersonalSkill<_EmptyInput, String> {
  static const String skillId = 'test.missing_evidence';

  @override
  String get id => skillId;

  @override
  Set<PersonalDataType> get requiredDataTypes => const <PersonalDataType>{};

  @override
  SkillSensitivity get sensitivity => SkillSensitivity.publicData;

  @override
  Future<SkillResult<String>> execute(
    _EmptyInput input,
    SkillExecutionContext context,
  ) async {
    return SkillResult<String>(
      value: '无证据结果',
      status: SkillStatus.success,
      containsPersonalData: false,
    );
  }
}
