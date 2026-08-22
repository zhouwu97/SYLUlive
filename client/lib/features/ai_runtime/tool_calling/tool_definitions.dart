import 'tool_call_models.dart';
import '../skills/competition_plan_action_skill.dart';
import '../skills/calendar_action_skill.dart';

/// 与本地 Validator 同源维护的固定 Tool Schema，模型不能动态新增能力。
List<ToolDefinition> buildStageSixToolDefinitions() => <ToolDefinition>[
      ToolDefinition(
        id: 'personal.schedule.today',
        description: '读取今天或指定日期的课表和空闲时段',
        parameters: _object(<String, dynamic>{
          'date': <String, dynamic>{'type': 'string', 'format': 'date'},
        }),
      ),
      ToolDefinition(
        id: 'personal.schedule.week',
        description: '读取不超过七天的课表',
        parameters: _object(<String, dynamic>{
          'week_containing': <String, dynamic>{
            'type': 'string',
            'format': 'date'
          },
        }),
      ),
      ToolDefinition(
        id: 'personal.academic.overview',
        description: '读取最小化成绩覆盖概览，不计算 GPA',
        parameters: _object(const <String, dynamic>{}),
      ),
      ToolDefinition(
        id: 'personal.physical.overview',
        description: '读取最近一次体测概览，不作医疗诊断',
        parameters: _object(const <String, dynamic>{}),
      ),
      ToolDefinition(
        id: 'personal.erke.overview',
        description: '读取二课总分、分类完成度和最近活动',
        parameters: _object(const <String, dynamic>{}),
      ),
      ToolDefinition(
        id: 'campus.competition.search',
        description: '检索校园公开竞赛目录',
        parameters: _object(
          <String, dynamic>{
            'keyword': const <String, dynamic>{'type': 'string'},
            'category_slug': const <String, dynamic>{'type': 'string'},
            'limit': const <String, dynamic>{
              'type': 'integer',
              'minimum': 1,
              'maximum': 20,
            },
          },
          required: const <String>['keyword'],
        ),
      ),
      ToolDefinition(
        id: 'get_competition_capability_profile',
        description: '读取用户明确授权的竞赛目标和结构化能力画像',
        parameters: _object(const <String, dynamic>{}),
      ),
      ToolDefinition(
        id: 'explain_competition_matches',
        description: '读取并解释平台已有的确定性“适合我”排序，不重新评分',
        parameters: _object(const <String, dynamic>{}),
      ),
      ToolDefinition(
        id: DraftAddCompetitionToPlanSkill.skillId,
        description: '基于服务端确定性推荐创建一个待用户确认的竞赛计划草稿，不会直接加入计划',
        parameters: _object(
          <String, dynamic>{
            'event_id': const <String, dynamic>{
              'type': 'integer',
              'minimum': 1,
            },
          },
          required: const <String>['event_id'],
        ),
      ),
      ToolDefinition(
        id: CalendarActionSkill.skillId,
        description: '创建日历操作待确认草稿；确认后才会创建、更新、删除事件或添加提醒',
        parameters: _object(
          <String, dynamic>{
            'action_type': <String, dynamic>{
              'type': 'string',
              'enum': <String>[
                'calendar_event_create',
                'calendar_event_update',
                'calendar_event_delete',
                'calendar_reminder_create',
              ],
            },
            'event_id': const <String, dynamic>{
              'type': 'integer',
              'minimum': 1,
            },
            'title': const <String, dynamic>{'type': 'string'},
            'description': const <String, dynamic>{'type': 'string'},
            'start_at': const <String, dynamic>{
              'type': 'string',
              'format': 'date-time'
            },
            'end_at': const <String, dynamic>{
              'type': 'string',
              'format': 'date-time'
            },
            'all_day': const <String, dynamic>{'type': 'boolean'},
            'location': const <String, dynamic>{'type': 'string'},
            'timezone': const <String, dynamic>{'type': 'string'},
            'reminder_minutes_before': const <String, dynamic>{
              'type': 'integer',
              'minimum': 0,
              'maximum': 10080,
            },
          },
          required: const <String>['action_type'],
        ),
      ),
      ...<String, String>{
        'personal.academic.gpa': '按固定公式计算 GPA 并列出纳入和排除课程',
        'personal.academic.credit_summary': '确定性统计已修、通过和未通过学分',
        'personal.academic.failure_risk': '列出未通过和无法确认的课程',
        'personal.graduation.readiness': '按已审核培养方案生成毕业清单',
      }.entries.map(
            (entry) => ToolDefinition(
              id: entry.key,
              description: entry.value,
              parameters: _object(const <String, dynamic>{}),
            ),
          ),
      ToolDefinition(
        id: 'personal.fitness.weekly_plan',
        description: '根据课表和体测概览生成有安全限制的本周运动计划',
        parameters: _object(<String, dynamic>{
          'week_containing': const <String, dynamic>{
            'type': 'string',
            'format': 'date',
          },
          'height_meters': const <String, dynamic>{
            'type': 'number',
            'minimum': 1.2,
            'maximum': 2.3,
          },
          'weight_kg': const <String, dynamic>{
            'type': 'number',
            'minimum': 30,
            'maximum': 250,
          },
          'reports_discomfort': const <String, dynamic>{'type': 'boolean'},
        }),
      ),
    ];

Map<String, dynamic> _object(
  Map<String, dynamic> properties, {
  List<String> required = const <String>[],
}) =>
    <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'properties': properties,
      if (required.isNotEmpty) 'required': required,
    };
