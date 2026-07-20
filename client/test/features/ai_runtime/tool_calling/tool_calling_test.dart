import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/ai_runtime/ai_model_provider.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/gateway/gateway_result.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/gateway/personal_data_gateway.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/models/academic_overview.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/models/academic_records.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/models/erke_overview.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/models/physical_overview.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/models/schedule_overview.dart';
import 'package:shenliyuan/features/ai_runtime/skills/academic_overview_skill.dart';
import 'package:shenliyuan/features/ai_runtime/skills/personal_skill.dart';
import 'package:shenliyuan/features/ai_runtime/skills/personal_skill_registry.dart';
import 'package:shenliyuan/features/ai_runtime/skills/skill_execution_context.dart';
import 'package:shenliyuan/features/ai_runtime/tool_calling/tool_call_models.dart';
import 'package:shenliyuan/features/ai_runtime/tool_calling/tool_call_validator.dart';
import 'package:shenliyuan/features/ai_runtime/tool_calling/tool_definitions.dart';
import 'package:shenliyuan/features/ai_runtime/tool_calling/tool_loop.dart';
import 'package:shenliyuan/features/ai_runtime/tool_calling/openai_tool_calling_model.dart';
import 'package:shenliyuan/features/ai_runtime/tool_calling/tool_permission.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';

void main() {
  group('OpenAIToolCallingModel', () {
    test('Responses API 使用安全函数名并解析 function_call', () async {
      late RequestOptions captured;
      final dio = Dio()
        ..httpClientAdapter = _CallbackAdapter((options) {
          captured = options;
          return _jsonResponse(<String, dynamic>{
            'output': <Object>[
              <String, dynamic>{
                'type': 'function_call',
                'call_id': 'call-1',
                'name': 'personal__academic__overview',
                'arguments': '{}',
              },
              <String, dynamic>{
                'type': 'function_call',
                'call_id': 'call-ignored',
                'name': 'personal__academic__overview',
                'arguments': '{}',
              },
            ],
          }, options);
        });
      final model = OpenAIToolCallingModel.fromConfig(
        config: const AIModelProviderConfig(
          kind: AIModelProviderKind.openAICompatible,
          endpoint: 'https://example.com',
          model: 'test-model',
          wireApi: OpenAIWireApi.responses,
        ),
        apiKey: 'test-key',
        dio: dio,
      );

      final turn = await model.nextTurn(
        messages: const <ToolConversationMessage>[
          ToolConversationMessage(
            role: ToolMessageRole.user,
            content: '查看学业概览',
          ),
        ],
        tools: <ToolDefinition>[
          ToolDefinition(
            id: AcademicOverviewSkill.skillId,
            description: '读取学业概览',
            parameters: const <String, dynamic>{'type': 'object'},
          ),
        ],
      );

      expect(captured.uri.path, '/responses');
      final payload = Map<String, dynamic>.from(captured.data as Map);
      expect((payload['tools'] as List).first['name'],
          'personal__academic__overview');
      expect(turn.toolCall?.tool, AcademicOverviewSkill.skillId);
      expect(turn.toolCall?.id, 'call-1');
    });

    test('Responses API 回传 function_call_output 并解析最终文本', () async {
      late RequestOptions captured;
      final dio = Dio()
        ..httpClientAdapter = _CallbackAdapter((options) {
          captured = options;
          return _jsonResponse(<String, dynamic>{
            'output': <Object>[
              <String, dynamic>{
                'type': 'message',
                'content': <Object>[
                  <String, dynamic>{
                    'type': 'output_text',
                    'text': '已完成分析。',
                  },
                ],
              },
            ],
          }, options);
        });
      final model = OpenAIToolCallingModel.fromConfig(
        config: const AIModelProviderConfig(
          kind: AIModelProviderKind.openAICompatible,
          endpoint: 'https://example.com/v1',
          model: 'test-model',
          wireApi: OpenAIWireApi.responses,
        ),
        apiKey: 'test-key',
        dio: dio,
      );
      final call = _academicCall('call-1');

      final turn = await model.nextTurn(
        messages: <ToolConversationMessage>[
          const ToolConversationMessage(
            role: ToolMessageRole.user,
            content: '查看学业概览',
          ),
          ToolConversationMessage(
            role: ToolMessageRole.assistant,
            content: '',
            toolCall: call,
          ),
          ToolConversationMessage(
            role: ToolMessageRole.tool,
            content: '{"status":"success"}',
            toolCallId: call.id,
            toolCall: call,
          ),
        ],
        tools: <ToolDefinition>[
          ToolDefinition(
            id: AcademicOverviewSkill.skillId,
            description: '读取学业概览',
            parameters: const <String, dynamic>{'type': 'object'},
          ),
        ],
      );

      final payload = Map<String, dynamic>.from(captured.data as Map);
      final input = (payload['input'] as List).cast<Map>();
      expect(input[1]['type'], 'function_call');
      expect(input[2]['type'], 'function_call_output');
      expect(input[2]['call_id'], 'call-1');
      expect(turn.text, '已完成分析。');
    });

    test('自动模式在 Responses 明确不兼容时回退 Chat Completions', () async {
      final paths = <String>[];
      final dio = Dio()
        ..httpClientAdapter = _CallbackAdapter((options) {
          paths.add(options.uri.path);
          if (options.uri.path.endsWith('/responses')) {
            return Future<ResponseBody>.value(
              ResponseBody.fromString(
                '{"error":{"message":"not found"}}',
                404,
                headers: <String, List<String>>{
                  Headers.contentTypeHeader: <String>['application/json'],
                },
              ),
            );
          }
          return _jsonResponse(<String, dynamic>{
            'choices': <Object>[
              <String, dynamic>{
                'message': <String, dynamic>{'content': '普通回答'},
              },
            ],
          }, options);
        });
      final model = OpenAIToolCallingModel.fromConfig(
        config: const AIModelProviderConfig(
          kind: AIModelProviderKind.openAICompatible,
          endpoint: 'https://api.deepseek.com',
          model: 'deepseek-v4-pro',
        ),
        apiKey: 'test-key',
        dio: dio,
      );

      final turn = await model.nextTurn(
        messages: const <ToolConversationMessage>[
          ToolConversationMessage(
            role: ToolMessageRole.user,
            content: '你好',
          ),
        ],
        tools: const <ToolDefinition>[],
      );

      expect(paths, <String>['/responses', '/chat/completions']);
      expect(turn.text, '普通回答');
    });
  });

  group('LocalToolCallValidator', () {
    const validator = LocalToolCallValidator();

    test('拒绝未知 Tool 和嵌套敏感标识', () {
      expect(
        () => validator.validate(
          LocalToolCall(id: '1', tool: 'unknown', arguments: const {}),
        ),
        throwsA(isA<ToolCallValidationException>()),
      );
      expect(
        () => validator.validate(
          LocalToolCall(
            id: '2',
            tool: AcademicOverviewSkill.skillId,
            arguments: const <String, dynamic>{
              'nested': <String, dynamic>{'student_id': 'x'},
            },
          ),
        ),
        throwsA(isA<ToolCallValidationException>()),
      );
    });

    test('拒绝越界和冲突日期参数', () {
      expect(
        () => validator.validate(
          LocalToolCall(
            id: '1',
            tool: 'personal.schedule.week',
            arguments: const <String, dynamic>{
              'start': '2026-07-20',
              'end': '2026-07-26',
              'week_containing': '2026-07-20',
            },
          ),
        ),
        throwsA(isA<ToolCallValidationException>()),
      );
      expect(
        () => validator.validate(
          LocalToolCall(
            id: '2',
            tool: 'campus.competition.search',
            arguments: const <String, dynamic>{
              'keyword': 'AI',
              'limit': 21,
            },
          ),
        ),
        throwsA(isA<ToolCallValidationException>()),
      );
    });
  });

  group('ToolPermissionManager', () {
    test('低敏感允许会话复用，中敏感强制降级为仅本次', () async {
      final prompt = _Prompt(ToolPermissionDecision.allowSession);
      final manager = ToolPermissionManager(prompt: prompt);
      final low = _preview(SkillSensitivity.low);
      expect(
        await manager.authorize(low),
        ToolPermissionDecision.allowSession,
      );
      expect(
        await manager.authorize(low),
        ToolPermissionDecision.allowSession,
      );
      expect(prompt.count, 1);

      expect(
        await manager.authorize(_preview(SkillSensitivity.medium)),
        ToolPermissionDecision.allowOnce,
      );
    });
  });

  group('LocalToolLoop', () {
    test('授权后执行最小化 Skill 并把证据回传模型', () async {
      final model = _ScriptedModel(<ToolModelTurn>[
        ToolModelTurn.call(_academicCall('call-1')),
        const ToolModelTurn.finalAnswer('已根据本地学业概览完成回答。'),
      ]);
      final audit = _AuditSink();
      final loop = _loop(model: model, audit: audit);

      final outcome = await loop.run(
        userMessage: '我的成绩数据完整吗？',
        tools: buildStageSixToolDefinitions(),
      );

      expect(outcome.status, ToolLoopStatus.completed);
      expect(outcome.answer, contains('本地学业概览'));
      expect(model.receivedMessages.last.content, contains('evidence'));
      expect(
          model.receivedMessages.last.content, isNot(contains('student_id')));
      expect(audit.entries.single.skillId, AcademicOverviewSkill.skillId);
      expect(audit.entries.single.status, SkillStatus.success.name);
    });

    test('未授权不执行 Skill 且不继续请求模型', () async {
      final gateway = _Gateway();
      final model = _ScriptedModel(<ToolModelTurn>[
        ToolModelTurn.call(_academicCall('call-1')),
      ]);
      final loop = _loop(
        model: model,
        gateway: gateway,
        decision: ToolPermissionDecision.denied,
      );

      final outcome = await loop.run(
        userMessage: '查看学业概览',
        tools: buildStageSixToolDefinitions(),
      );

      expect(outcome.status, ToolLoopStatus.permissionDenied);
      expect(gateway.academicReads, 0);
      expect(model.turnsRequested, 1);
    });

    test('校园公共模型不能接收个人 Skill 结果', () async {
      final gateway = _Gateway();
      final model = _ScriptedModel(
        <ToolModelTurn>[ToolModelTurn.call(_academicCall('call-1'))],
        kind: AIModelProviderKind.campusPublic,
      );
      final outcome = await _loop(model: model, gateway: gateway).run(
        userMessage: '查看学业概览',
        tools: buildStageSixToolDefinitions(),
      );

      expect(outcome.status, ToolLoopStatus.rejected);
      expect(outcome.warnings.single, contains('公共模型'));
      expect(gateway.academicReads, 0);
    });

    test('已注册但未在本轮下发的 Tool 仍被拒绝', () async {
      final gateway = _Gateway();
      final model = _ScriptedModel(
        <ToolModelTurn>[ToolModelTurn.call(_academicCall('call-1'))],
      );
      final outcome = await _loop(model: model, gateway: gateway).run(
        userMessage: '尝试绕过功能开关',
        tools: const <ToolDefinition>[],
      );
      expect(outcome.status, ToolLoopStatus.rejected);
      expect(gateway.academicReads, 0);
    });

    test('拒绝未知 Tool、重复调用和超过三轮的调用', () async {
      final unknown = _ScriptedModel(<ToolModelTurn>[
        ToolModelTurn.call(
          LocalToolCall(id: 'x', tool: 'personal.all', arguments: const {}),
        ),
      ]);
      expect(
        (await _loop(model: unknown).run(
          userMessage: '恶意请求',
          tools: buildStageSixToolDefinitions(),
        ))
            .status,
        ToolLoopStatus.rejected,
      );

      final repeated = _ScriptedModel(<ToolModelTurn>[
        ToolModelTurn.call(_academicCall('1')),
        ToolModelTurn.call(_academicCall('2')),
      ]);
      expect(
        (await _loop(model: repeated).run(
          userMessage: '重复',
          tools: buildStageSixToolDefinitions(),
        ))
            .warnings
            .single,
        contains('重复'),
      );
    });

    test('账号代际变化立即取消且不读取 Gateway', () async {
      var generation = 1;
      final gateway = _Gateway();
      final model = _ScriptedModel(
        <ToolModelTurn>[ToolModelTurn.call(_academicCall('1'))],
        onTurn: () => generation++,
      );
      final outcome = await _loop(
        model: model,
        gateway: gateway,
        generation: () => generation,
      ).run(
        userMessage: '查看学业概览',
        tools: buildStageSixToolDefinitions(),
      );

      expect(outcome.status, ToolLoopStatus.cancelled);
      expect(model.cancelled, isTrue);
      expect(gateway.academicReads, 0);
    });

    test('单次 Skill 超时后失败关闭', () async {
      final gateway = _Gateway(blockAcademic: true);
      final model = _ScriptedModel(
        <ToolModelTurn>[ToolModelTurn.call(_academicCall('1'))],
      );
      final outcome = await _loop(
        model: model,
        gateway: gateway,
        timeout: const Duration(milliseconds: 20),
      ).run(
        userMessage: '查看学业概览',
        tools: buildStageSixToolDefinitions(),
      );

      expect(outcome.status, ToolLoopStatus.failed);
      expect(outcome.warnings.single, contains('超时'));
    });

    test('模型服务错误会原样反馈给界面', () async {
      final model = _ScriptedModel(
        const <ToolModelTurn>[],
        turnError: const AIModelProviderException('请求协议与服务不兼容'),
      );

      final outcome = await _loop(model: model).run(
        userMessage: '查看学业概览',
        tools: buildStageSixToolDefinitions(),
      );

      expect(outcome.status, ToolLoopStatus.failed);
      expect(outcome.warnings, <String>['请求协议与服务不兼容']);
    });

    test('审计对象不包含个人数值和请求正文', () {
      final json = ToolAuditEntry(
        timestamp: DateTime.utc(2026, 7, 20),
        skillId: AcademicOverviewSkill.skillId,
        permission: ToolPermissionDecision.allowOnce,
        providerKind: AIModelProviderKind.openAICompatible,
        dataTypes: const <PersonalDataType>{PersonalDataType.academic},
        status: 'success',
      ).toJson();
      expect(json.keys, <String>[
        'timestamp',
        'skill_id',
        'permission',
        'provider_type',
        'data_types',
        'status',
      ]);
      expect(json.toString(), isNot(contains('score')));
      expect(json.toString(), isNot(contains('content')));
    });
  });
}

class _CallbackAdapter implements HttpClientAdapter {
  _CallbackAdapter(this.callback);

  final Future<ResponseBody> Function(RequestOptions options) callback;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return callback(options);
  }

  @override
  void close({bool force = false}) {}
}

Future<ResponseBody> _jsonResponse(
  Map<String, dynamic> data,
  RequestOptions _,
) async {
  return ResponseBody.fromString(
    jsonEncode(data),
    200,
    headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>['application/json'],
    },
  );
}

LocalToolLoop _loop({
  required _ScriptedModel model,
  _Gateway? gateway,
  _AuditSink? audit,
  ToolPermissionDecision decision = ToolPermissionDecision.allowOnce,
  int Function()? generation,
  Duration timeout = const Duration(seconds: 1),
}) {
  final dataGateway = gateway ?? _Gateway();
  return LocalToolLoop(
    registry: PersonalSkillRegistry(<PersonalSkill<dynamic, dynamic>>[
      AcademicOverviewSkill(),
    ]),
    executionContext: SkillExecutionContext(
      personalDataGateway: dataGateway,
      clock: () => DateTime.utc(2026, 7, 20),
    ),
    model: model,
    permissionManager: ToolPermissionManager(prompt: _Prompt(decision)),
    auditSink: audit ?? _AuditSink(),
    accountGeneration: generation ?? () => 1,
    skillTimeout: timeout,
  );
}

LocalToolCall _academicCall(String id) => LocalToolCall(
      id: id,
      tool: AcademicOverviewSkill.skillId,
      arguments: const <String, dynamic>{},
    );

ToolPermissionPreview _preview(SkillSensitivity sensitivity) =>
    ToolPermissionPreview(
      toolId: 'test',
      sensitivity: sensitivity,
      destination: 'test',
      dataItems: const <ToolDataPreviewItem>[
        ToolDataPreviewItem(
          dataType: PersonalDataType.academic,
          label: '学业概览',
        ),
      ],
      excludedDataLabels: const <String>[],
      outputFields: const <String>[],
    );

class _Prompt implements ToolPermissionPrompt {
  _Prompt(this.decision);

  final ToolPermissionDecision decision;
  int count = 0;

  @override
  Future<ToolPermissionDecision> request(ToolPermissionPreview preview) async {
    count++;
    return decision;
  }
}

class _AuditSink implements ToolAuditSink {
  final List<ToolAuditEntry> entries = <ToolAuditEntry>[];

  @override
  Future<void> record(ToolAuditEntry entry) async => entries.add(entry);
}

class _ScriptedModel implements ToolCallingModel {
  _ScriptedModel(
    this.turns, {
    this.kind = AIModelProviderKind.openAICompatible,
    this.onTurn,
    this.turnError,
  });

  final List<ToolModelTurn> turns;
  final AIModelProviderKind kind;
  final void Function()? onTurn;
  final Object? turnError;
  final List<ToolConversationMessage> receivedMessages =
      <ToolConversationMessage>[];
  int turnsRequested = 0;
  bool cancelled = false;

  @override
  String get destinationLabel => kind.displayName;

  @override
  AIModelProviderKind get providerKind => kind;

  @override
  Future<ToolModelTurn> nextTurn({
    required List<ToolConversationMessage> messages,
    required List<ToolDefinition> tools,
  }) async {
    receivedMessages
      ..clear()
      ..addAll(messages);
    onTurn?.call();
    if (turnError != null) throw turnError!;
    return turns[turnsRequested++];
  }

  @override
  Future<void> cancel() async => cancelled = true;
}

class _Gateway implements PersonalDataGateway {
  _Gateway({this.blockAcademic = false});

  final bool blockAcademic;
  int academicReads = 0;

  @override
  Future<GatewayResult<AcademicRecords>> getAcademicRecords() =>
      throw UnimplementedError();

  @override
  Future<GatewayResult<AcademicOverview>> getAcademicOverview() async {
    academicReads++;
    if (blockAcademic) {
      return Completer<GatewayResult<AcademicOverview>>().future;
    }
    final fetchedAt = DateTime.utc(2026, 7, 20, 8);
    return GatewayResult<AcademicOverview>(
      status: GatewayStatus.available,
      source: PersonalDataSource.localEncryptedVault,
      data: AcademicOverview(
        terms: <AcademicTermOverview>[
          AcademicTermOverview(
            year: '2025-2026',
            semester: 2,
            courseCount: 8,
            fetchedAt: fetchedAt,
          ),
        ],
        totalRecordedCourses: 8,
        hasAcademicSituation: true,
        academicSituationFetchedAt: fetchedAt,
      ),
      fetchedAt: fetchedAt,
      expiresAt: fetchedAt.add(const Duration(days: 7)),
    );
  }

  @override
  Future<void> close() async {}

  @override
  Future<GatewayResult<ErkeOverview>> getErkeOverview() =>
      throw UnimplementedError();

  @override
  Future<GatewayResult<PhysicalOverview>> getPhysicalOverview() =>
      throw UnimplementedError();

  @override
  Future<GatewayResult<ScheduleOverview>> getScheduleOverview({
    required DateTime start,
    required DateTime end,
  }) =>
      throw UnimplementedError();
}
