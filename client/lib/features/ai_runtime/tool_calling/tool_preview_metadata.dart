import '../../campus_data/storage/personal_snapshot_models.dart';
import '../skills/academic_overview_skill.dart';
import '../skills/competition_search_skill.dart';
import '../skills/deterministic_skills.dart';
import '../skills/erke_overview_skill.dart';
import '../skills/physical_overview_skill.dart';
import '../skills/schedule_skill_models.dart';
import '../skills/today_schedule_skill.dart';
import '../skills/week_schedule_skill.dart';
import 'tool_call_models.dart';

class ToolPreviewRequest {
  const ToolPreviewRequest({
    required this.toolId,
    required this.validatedInput,
    required this.dataTypes,
  });

  final String toolId;
  final Object validatedInput;
  final Set<PersonalDataType> dataTypes;
}

class ToolPermissionPreviewMetadata {
  ToolPermissionPreviewMetadata({
    required List<ToolDataPreviewItem> inputItems,
    required List<String> excludedDataLabels,
    required List<String> outputFields,
  })  : inputItems = List<ToolDataPreviewItem>.unmodifiable(inputItems),
        excludedDataLabels = List<String>.unmodifiable(excludedDataLabels),
        outputFields = List<String>.unmodifiable(outputFields);

  final List<ToolDataPreviewItem> inputItems;
  final List<String> excludedDataLabels;
  final List<String> outputFields;
}

abstract interface class ToolPreviewMetadataSource {
  Future<ToolPermissionPreviewMetadata> describe(ToolPreviewRequest request);
}

class DefaultToolPreviewMetadataSource implements ToolPreviewMetadataSource {
  const DefaultToolPreviewMetadataSource();

  static const _credentials = <String>[
    '教务密码',
    'Cookie',
    'API Key',
  ];

  @override
  Future<ToolPermissionPreviewMetadata> describe(
    ToolPreviewRequest request,
  ) async {
    final metadata = switch (request.toolId) {
      TodayScheduleSkill.skillId => _today(request.validatedInput),
      WeekScheduleSkill.skillId => _week(request.validatedInput),
      AcademicOverviewSkill.skillId => _academicOverview(),
      PhysicalOverviewSkill.skillId => _physicalOverview(),
      ErkeOverviewSkill.skillId => _erkeOverview(),
      CompetitionSearchSkill.skillId => _competitionSearch(),
      AcademicGpaSkill.skillId => _gpa(),
      AcademicCreditSummarySkill.skillId => _creditSummary(),
      AcademicFailureRiskSkill.skillId => _failureRisk(),
      GraduationReadinessSkill.skillId => _graduationReadiness(),
      CompetitionFitSkill.skillId => _competitionFit(request.validatedInput),
      FitnessWeeklyPlanSkill.skillId => _fitness(request.validatedInput),
      _ => throw StateError('Tool 授权元数据未配置'),
    };
    final describedDataTypes = metadata.inputItems
        .map((item) => item.dataType)
        .whereType<PersonalDataType>()
        .toSet();
    if (describedDataTypes.length != request.dataTypes.length ||
        !describedDataTypes.containsAll(request.dataTypes)) {
      throw StateError('Tool 授权元数据与数据权限声明不一致');
    }
    return metadata;
  }

  ToolPermissionPreviewMetadata _today(Object input) {
    final value = input as TodayScheduleInput;
    return _metadata(
      inputItems: <ToolDataPreviewItem>[
        ToolDataPreviewItem(
          dataType: PersonalDataType.schedule,
          label: value.date == null ? '今天的课表' : '${_date(value.date!)} 的课表',
        ),
      ],
      excluded: const <String>['其他日期课表', '成绩、体测和二课数据', ..._credentials],
      output: const <String>['课程、时间、地点、空闲时段'],
    );
  }

  ToolPermissionPreviewMetadata _week(Object input) {
    final value = input as WeekScheduleInput;
    final range = value.weekContaining != null
        ? '${_date(value.weekContaining!)} 所在周'
        : value.start != null && value.end != null
            ? '${_date(value.start!)} 至 ${_date(value.end!)}'
            : '本周';
    return _metadata(
      inputItems: <ToolDataPreviewItem>[
        ToolDataPreviewItem(
          dataType: PersonalDataType.schedule,
          label: '$range的课表',
        ),
      ],
      excluded: const <String>['范围外课表', '成绩、体测和二课数据', ..._credentials],
      output: const <String>['课程、日期、时间、地点'],
    );
  }

  ToolPermissionPreviewMetadata _academicOverview() => _metadata(
        inputItems: const <ToolDataPreviewItem>[
          ToolDataPreviewItem(
            dataType: PersonalDataType.academic,
            label: '课程数量、学期覆盖和学业情况可用状态',
          ),
        ],
        excluded: const <String>[
          '课程分数',
          'GPA',
          '学分',
          '挂科记录',
          '完整成绩原始响应',
          ..._credentials,
        ],
        output: const <String>['课程数量、覆盖学期、缺失状态'],
      );

  ToolPermissionPreviewMetadata _physicalOverview() => _metadata(
        inputItems: const <ToolDataPreviewItem>[
          ToolDataPreviewItem(
            dataType: PersonalDataType.physical,
            label: '最近一次体测概览',
          ),
        ],
        excluded: const <String>['体测以外健康信息', '成绩和课表数据', ..._credentials],
        output: const <String>['最近学年、总分、项目结果'],
      );

  ToolPermissionPreviewMetadata _erkeOverview() => _metadata(
        inputItems: const <ToolDataPreviewItem>[
          ToolDataPreviewItem(
            dataType: PersonalDataType.erke,
            label: '二课总分、分类完成度和最近活动',
          ),
        ],
        excluded: const <String>['未请求的二课明细', '成绩和课表数据', ..._credentials],
        output: const <String>['总分、分类完成度、最近活动'],
      );

  ToolPermissionPreviewMetadata _competitionSearch() => _metadata(
        inputItems: const <ToolDataPreviewItem>[],
        excluded: const <String>['个人画像、成绩、课表、体测和二课数据', ..._credentials],
        output: const <String>['公开赛事名称、摘要、分类、报名时间和官方链接'],
      );

  ToolPermissionPreviewMetadata _gpa() => _metadata(
        inputItems: const <ToolDataPreviewItem>[
          ToolDataPreviewItem(
            dataType: PersonalDataType.academic,
            label: '课程成绩、课程学分、课程性质、学期、补考与重修信息',
          ),
        ],
        excluded: const <String>['姓名', '不需要的个人资料', ..._credentials],
        output: const <String>[
          'GPA',
          '纳入课程和学分',
          '排除课程及原因',
          '无法解析项',
        ],
      );

  ToolPermissionPreviewMetadata _creditSummary() => _metadata(
        inputItems: const <ToolDataPreviewItem>[
          ToolDataPreviewItem(
            dataType: PersonalDataType.academic,
            label: '课程成绩、课程学分和课程性质',
          ),
        ],
        excluded: const <String>['姓名', '不需要的个人资料', ..._credentials],
        output: const <String>[
          '已修学分',
          '通过学分',
          '未通过学分',
          '必修未通过学分',
          '未知学分',
        ],
      );

  ToolPermissionPreviewMetadata _failureRisk() => _metadata(
        inputItems: const <ToolDataPreviewItem>[
          ToolDataPreviewItem(
            dataType: PersonalDataType.academic,
            label: '课程成绩、课程学分和课程性质',
          ),
        ],
        excluded: const <String>['姓名', '不需要的个人资料', ..._credentials],
        output: const <String>['未通过课程', '无法确认课程', '相关学分'],
      );

  ToolPermissionPreviewMetadata _graduationReadiness() => _metadata(
        inputItems: const <ToolDataPreviewItem>[
          ToolDataPreviewItem(
            dataType: PersonalDataType.academic,
            label: '成绩记录',
          ),
          ToolDataPreviewItem(
            dataType: PersonalDataType.erke,
            label: '二课概览',
          ),
          ToolDataPreviewItem(label: '已审核培养方案规则'),
        ],
        excluded: const <String>['未审核政策推断', '姓名', ..._credentials],
        output: const <String>[
          '毕业要求完成状态',
          '学分缺口',
          '阻断项',
          '数据不足警告',
        ],
      );

  ToolPermissionPreviewMetadata _competitionFit(Object input) {
    final value = input as CompetitionFitInput;
    final goals = value.goals.isEmpty ? '未指定目标' : value.goals.join('、');
    return _metadata(
      inputItems: <ToolDataPreviewItem>[
        ToolDataPreviewItem(
          dataType: PersonalDataType.studentProfile,
          label: '年级、学院、专业和本次竞赛目标（$goals）',
        ),
      ],
      excluded: const <String>[
        '课程成绩',
        'GPA',
        '学分',
        '挂科记录',
        '完整成绩原始响应',
        ..._credentials,
      ],
      output: const <String>[
        '赛事适配状态',
        '适配评分',
        '匹配理由',
        '强推荐门槛状态',
      ],
    );
  }

  ToolPermissionPreviewMetadata _fitness(Object input) {
    final value = input as FitnessWeeklyPlanInput;
    final provided = <String>[
      if (value.heightMeters != null) '身高',
      if (value.weightKg != null) '体重',
      if (value.reportsDiscomfort != null) '不适状态',
    ];
    return _metadata(
      inputItems: <ToolDataPreviewItem>[
        ToolDataPreviewItem(
          dataType: PersonalDataType.schedule,
          label: value.weekContaining == null
              ? '本周课表'
              : '${_date(value.weekContaining!)} 所在周课表',
        ),
        const ToolDataPreviewItem(
          dataType: PersonalDataType.physical,
          label: '最近体测概览',
        ),
        if (provided.isNotEmpty)
          ToolDataPreviewItem(label: '用户主动填写的${provided.join('、')}'),
      ],
      excluded: const <String>['病历和诊断信息', '成绩和二课数据', ..._credentials],
      output: const <String>['建议时间窗口', '训练安排', '安全提示'],
    );
  }

  ToolPermissionPreviewMetadata _metadata({
    required List<ToolDataPreviewItem> inputItems,
    required List<String> excluded,
    required List<String> output,
  }) =>
      ToolPermissionPreviewMetadata(
        inputItems: inputItems,
        excludedDataLabels: excluded,
        outputFields: output,
      );

  String _date(DateTime value) => '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
