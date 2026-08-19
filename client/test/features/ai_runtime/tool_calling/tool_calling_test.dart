import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/ai_runtime/ai_model_provider.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/gateway/gateway_result.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/gateway/personal_data_gateway.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/gateway/unavailable_personal_data_gateway.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/models/academic_overview.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/models/academic_records.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/models/erke_overview.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/models/physical_overview.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/models/schedule_overview.dart';
import 'package:shenliyuan/features/ai_runtime/skills/academic_overview_skill.dart';
import 'package:shenliyuan/features/ai_runtime/skills/competition_search_skill.dart';
import 'package:shenliyuan/features/ai_runtime/skills/competition_advisor_skills.dart';
import 'package:shenliyuan/features/ai_runtime/skills/competition_plan_action_skill.dart';
import 'package:shenliyuan/features/ai_runtime/skills/deterministic_skills.dart';
import 'package:shenliyuan/features/ai_runtime/skills/erke_overview_skill.dart';
import 'package:shenliyuan/features/ai_runtime/skills/personal_skill.dart';
import 'package:shenliyuan/features/ai_runtime/skills/personal_skill_registry.dart';
import 'package:shenliyuan/features/ai_runtime/skills/physical_overview_skill.dart';
import 'package:shenliyuan/features/ai_runtime/skills/skill_execution_context.dart';
import 'package:shenliyuan/features/ai_runtime/skills/today_schedule_skill.dart';
import 'package:shenliyuan/features/ai_runtime/skills/week_schedule_skill.dart';
import 'package:shenliyuan/features/ai_runtime/tool_calling/tool_call_models.dart';
import 'package:shenliyuan/features/ai_runtime/tool_calling/tool_call_validator.dart';
import 'package:shenliyuan/features/ai_runtime/tool_calling/tool_definitions.dart';
import 'package:shenliyuan/features/ai_runtime/tool_calling/tool_loop.dart';
import 'package:shenliyuan/features/ai_runtime/tool_calling/openai_tool_calling_model.dart';
import 'package:shenliyuan/features/ai_runtime/tool_calling/tool_permission.dart';
import 'package:shenliyuan/features/ai_runtime/tool_calling/tool_preview_metadata.dart';
import 'package:shenliyuan/features/ai_runtime/tool_calling/skill_result_serializer.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';
import 'package:shenliyuan/models/competition.dart';

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

    test('DeepSeek 自动模式使用 Chat Completions 且不发送 tool_choice', () async {
      late RequestOptions captured;
      var requestCount = 0;
      final dio = Dio()
        ..httpClientAdapter = _CallbackAdapter((options) {
          requestCount++;
          captured = options;
          return _jsonResponse(<String, dynamic>{
            'choices': <Object>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': '',
                  'reasoning_content': '需要调用连接测试工具。',
                  'tool_calls': <Object>[
                    <String, dynamic>{
                      'id': 'call-probe',
                      'type': 'function',
                      'function': <String, dynamic>{
                        'name': 'connection_test',
                        'arguments': '{"status":"ok"}',
                      },
                    },
                  ],
                },
              },
            ],
          }, options);
        });
      final model = OpenAIToolCallingModel.fromConfig(
        config: const AIModelProviderConfig(
          kind: AIModelProviderKind.openAICompatible,
          endpoint: 'https://api.deepseek.com/v1',
          model: 'deepseek-v4-flash',
        ),
        apiKey: 'test-key',
        dio: dio,
      );

      await model.probeToolCalling();

      expect(requestCount, 1);
      expect(captured.uri.path, '/chat/completions');
      final payload = Map<String, dynamic>.from(captured.data as Map);
      expect(payload.containsKey('tool_choice'), isFalse);
      expect((payload['tools'] as List), isNotEmpty);
    });

    test('Claude Messages 解析 tool_use 并在下一轮回传 tool_result', () async {
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..httpClientAdapter = _CallbackAdapter((options) {
          requests.add(options);
          if (requests.length == 1) {
            return _jsonResponse(<String, dynamic>{
              'content': <Object>[
                <String, dynamic>{
                  'type': 'text',
                  'text': '正在读取本地学业概览。',
                },
                <String, dynamic>{
                  'type': 'tool_use',
                  'id': 'toolu-1',
                  'name': 'personal__academic__overview',
                  'input': <String, dynamic>{},
                },
              ],
              'stop_reason': 'tool_use',
            }, options);
          }
          return _jsonResponse(<String, dynamic>{
            'content': <Object>[
              <String, dynamic>{'type': 'text', 'text': '已完成分析。'},
              <String, dynamic>{'type': 'text', 'text': '结果正常。'},
            ],
            'stop_reason': 'end_turn',
          }, options);
        });
      final model = OpenAIToolCallingModel.fromConfig(
        config: const AIModelProviderConfig(
          kind: AIModelProviderKind.openAICompatible,
          endpoint: 'https://api.anthropic.com/v1',
          model: 'claude-sonnet-4-5',
        ),
        apiKey: 'claude-key',
        dio: dio,
      );
      final tools = <ToolDefinition>[
        ToolDefinition(
          id: AcademicOverviewSkill.skillId,
          description: '读取学业概览',
          parameters: const <String, dynamic>{'type': 'object'},
        ),
      ];

      final firstTurn = await model.nextTurn(
        messages: const <ToolConversationMessage>[
          ToolConversationMessage(
            role: ToolMessageRole.system,
            content: '只使用提供的工具。',
          ),
          ToolConversationMessage(
            role: ToolMessageRole.user,
            content: '查看学业概览',
          ),
        ],
        tools: tools,
      );

      expect(requests.first.uri.path, '/v1/messages');
      expect(requests.first.headers['x-api-key'], 'claude-key');
      expect(requests.first.headers['anthropic-version'], '2023-06-01');
      expect(requests.first.headers.containsKey('Authorization'), isFalse);
      final firstPayload =
          Map<String, dynamic>.from(requests.first.data as Map);
      expect(firstPayload['system'], '只使用提供的工具。');
      expect(firstPayload['max_tokens'], 4096);
      final tool = Map<String, dynamic>.from(
        (firstPayload['tools'] as List).first as Map,
      );
      expect(tool['name'], 'personal__academic__overview');
      expect(tool['input_schema'], <String, dynamic>{'type': 'object'});
      expect(firstTurn.toolCall?.id, 'toolu-1');
      expect(firstTurn.toolCall?.tool, AcademicOverviewSkill.skillId);
      expect(firstTurn.assistantContent, '正在读取本地学业概览。');

      final call = firstTurn.toolCall!;
      final secondTurn = await model.nextTurn(
        messages: <ToolConversationMessage>[
          const ToolConversationMessage(
            role: ToolMessageRole.system,
            content: '只使用提供的工具。',
          ),
          const ToolConversationMessage(
            role: ToolMessageRole.user,
            content: '查看学业概览',
          ),
          ToolConversationMessage(
            role: ToolMessageRole.assistant,
            content: firstTurn.assistantContent,
            toolCall: call,
          ),
          ToolConversationMessage(
            role: ToolMessageRole.tool,
            content: '{"status":"success"}',
            toolCallId: call.id,
            toolCall: call,
          ),
        ],
        tools: tools,
      );

      final secondPayload =
          Map<String, dynamic>.from(requests.last.data as Map);
      final messages = (secondPayload['messages'] as List).cast<Map>();
      final assistantBlocks = (messages[1]['content'] as List).cast<Map>();
      expect(
        assistantBlocks.map((block) => block['type']),
        <String>['text', 'tool_use'],
      );
      expect(assistantBlocks.last['id'], 'toolu-1');
      final resultBlocks = (messages[2]['content'] as List).cast<Map>();
      expect(resultBlocks.single['type'], 'tool_result');
      expect(resultBlocks.single['tool_use_id'], 'toolu-1');
      expect(resultBlocks.single['content'], '{"status":"success"}');
      expect(secondTurn.text, '已完成分析。\n结果正常。');
    });

    test('Claude 连接探测会强制指定工具并禁用并行工具调用', () async {
      late RequestOptions captured;
      final dio = Dio()
        ..httpClientAdapter = _CallbackAdapter((options) {
          captured = options;
          return _jsonResponse(<String, dynamic>{
            'content': <Object>[
              <String, dynamic>{
                'type': 'tool_use',
                'id': 'toolu-probe',
                'name': 'connection_test',
                'input': <String, dynamic>{'status': 'ok'},
              },
            ],
          }, options);
        });
      final model = OpenAIToolCallingModel.fromConfig(
        config: const AIModelProviderConfig(
          kind: AIModelProviderKind.openAICompatible,
          endpoint: 'https://api.anthropic.com',
          model: 'claude-sonnet-4-5',
        ),
        apiKey: 'claude-key',
        dio: dio,
      );

      await model.probeToolCalling();

      final payload = Map<String, dynamic>.from(captured.data as Map);
      final choice = Map<String, dynamic>.from(payload['tool_choice'] as Map);
      expect(choice['type'], 'tool');
      expect(choice['name'], 'connection_test');
      expect(choice['disable_parallel_tool_use'], isTrue);
    });

    test('Chat Completions 完整回传工具调用的推理上下文', () async {
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..httpClientAdapter = _CallbackAdapter((options) {
          requests.add(options);
          if (requests.length == 1) {
            return _jsonResponse(<String, dynamic>{
              'choices': <Object>[
                <String, dynamic>{
                  'message': <String, dynamic>{
                    'content': '正在读取本地学业概览。',
                    'reasoning_content': ' 保留首尾空格的推理上下文 ',
                    'tool_calls': <Object>[
                      <String, dynamic>{
                        'id': 'call-1',
                        'type': 'function',
                        'function': <String, dynamic>{
                          'name': 'personal__academic__overview',
                          'arguments': '{}',
                        },
                      },
                    ],
                  },
                },
              ],
            }, options);
          }
          return _jsonResponse(<String, dynamic>{
            'choices': <Object>[
              <String, dynamic>{
                'message': <String, dynamic>{'content': '已完成分析。'},
              },
            ],
          }, options);
        });
      final model = OpenAIToolCallingModel.fromConfig(
        config: const AIModelProviderConfig(
          kind: AIModelProviderKind.openAICompatible,
          endpoint: 'https://api.deepseek.com',
          model: 'deepseek-v4-flash',
          wireApi: OpenAIWireApi.chatCompletions,
        ),
        apiKey: 'test-key',
        dio: dio,
      );
      final tools = <ToolDefinition>[
        ToolDefinition(
          id: AcademicOverviewSkill.skillId,
          description: '读取学业概览',
          parameters: const <String, dynamic>{'type': 'object'},
        ),
      ];

      final firstTurn = await model.nextTurn(
        messages: const <ToolConversationMessage>[
          ToolConversationMessage(
            role: ToolMessageRole.user,
            content: '查看学业概览',
          ),
        ],
        tools: tools,
      );
      expect(firstTurn.assistantContent, '正在读取本地学业概览。');
      expect(firstTurn.reasoningContent, ' 保留首尾空格的推理上下文 ');

      final call = firstTurn.toolCall!;
      await model.nextTurn(
        messages: <ToolConversationMessage>[
          const ToolConversationMessage(
            role: ToolMessageRole.user,
            content: '查看学业概览',
          ),
          ToolConversationMessage(
            role: ToolMessageRole.assistant,
            content: firstTurn.assistantContent,
            toolCall: call,
            reasoningContent: firstTurn.reasoningContent,
          ),
          ToolConversationMessage(
            role: ToolMessageRole.tool,
            content: '{"status":"success"}',
            toolCallId: call.id,
            toolCall: call,
          ),
        ],
        tools: tools,
      );

      final secondPayload =
          Map<String, dynamic>.from(requests.last.data as Map);
      final messages = (secondPayload['messages'] as List).cast<Map>();
      expect(messages[1]['content'], '正在读取本地学业概览。');
      expect(
        messages[1]['reasoning_content'],
        ' 保留首尾空格的推理上下文 ',
      );
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
          endpoint: 'https://example.com',
          model: 'test-model',
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

    test('未知服务可从两种 OpenAI 协议继续回退 Anthropic Messages', () async {
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..httpClientAdapter = _CallbackAdapter((options) {
          requests.add(options);
          if (options.uri.path == '/responses') {
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
          if (options.uri.path == '/chat/completions') {
            return Future<ResponseBody>.value(
              ResponseBody.fromString(
                '{"error":{"message":"method not allowed"}}',
                405,
                headers: <String, List<String>>{
                  Headers.contentTypeHeader: <String>['application/json'],
                },
              ),
            );
          }
          return _jsonResponse(<String, dynamic>{
            'content': <Object>[
              <String, dynamic>{'type': 'text', 'text': 'Claude 网关回答'},
            ],
          }, options);
        });
      final model = OpenAIToolCallingModel.fromConfig(
        config: const AIModelProviderConfig(
          kind: AIModelProviderKind.openAICompatible,
          endpoint: 'https://models.example.com',
          model: 'claude-compatible',
        ),
        apiKey: 'gateway-key',
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

      expect(
        requests.map((request) => request.uri.path),
        <String>['/responses', '/chat/completions', '/v1/messages'],
      );
      expect(requests.last.headers['x-api-key'], 'gateway-key');
      expect(requests.last.headers['Authorization'], 'Bearer gateway-key');
      expect(turn.text, 'Claude 网关回答');
    });

    test('自动协议遇到鉴权失败时不会继续回退', () async {
      var requestCount = 0;
      final dio = Dio()
        ..httpClientAdapter = _CallbackAdapter((options) {
          requestCount++;
          return Future<ResponseBody>.value(
            ResponseBody.fromString(
              '{"error":{"message":"invalid api key"}}',
              401,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            ),
          );
        });
      final model = OpenAIToolCallingModel.fromConfig(
        config: const AIModelProviderConfig(
          kind: AIModelProviderKind.openAICompatible,
          endpoint: 'https://models.example.com',
          model: 'test-model',
        ),
        apiKey: 'invalid-key',
        dio: dio,
      );

      await expectLater(
        model.nextTurn(
          messages: const <ToolConversationMessage>[
            ToolConversationMessage(
              role: ToolMessageRole.user,
              content: '你好',
            ),
          ],
          tools: const <ToolDefinition>[],
        ),
        throwsA(
          isA<AIModelProviderException>().having(
            (error) => error.message,
            'message',
            'invalid api key',
          ),
        ),
      );
      expect(requestCount, 1);
    });

    test('Chat Completions 的参数错误保留服务端原始信息', () async {
      final dio = Dio()
        ..httpClientAdapter = _CallbackAdapter((options) {
          return Future<ResponseBody>.value(
            ResponseBody.fromString(
              '{"error":{"message":"thinking mode rejects this parameter"}}',
              422,
              headers: <String, List<String>>{
                Headers.contentTypeHeader: <String>['application/json'],
              },
            ),
          );
        });
      final model = OpenAIToolCallingModel.fromConfig(
        config: const AIModelProviderConfig(
          kind: AIModelProviderKind.openAICompatible,
          endpoint: 'https://api.deepseek.com',
          model: 'deepseek-v4-flash',
          wireApi: OpenAIWireApi.chatCompletions,
        ),
        apiKey: 'test-key',
        dio: dio,
      );

      await expectLater(
        model.nextTurn(
          messages: const <ToolConversationMessage>[
            ToolConversationMessage(
              role: ToolMessageRole.user,
              content: '你好',
            ),
          ],
          tools: const <ToolDefinition>[],
        ),
        throwsA(
          isA<AIModelProviderException>().having(
            (error) => error.message,
            'message',
            'thinking mode rejects this parameter',
          ),
        ),
      );
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

    test('竞赛顾问两个只读 Tool 均不接受任何变更参数', () {
      for (final toolId in <String>{
        CompetitionCapabilityProfileSkill.skillId,
        ExplainCompetitionMatchesSkill.skillId,
      }) {
        final definition = buildStageSixToolDefinitions()
            .singleWhere((item) => item.id == toolId);
        expect(definition.parameters['additionalProperties'], isFalse);
        expect(definition.parameters['properties'], isEmpty);
        expect(
          validator
              .validate(LocalToolCall(
                id: 'valid-$toolId',
                tool: toolId,
                arguments: const <String, dynamic>{},
              ))
              .input,
          isA<EmptyCompetitionAdvisorInput>(),
        );
        expect(
          () => validator.validate(LocalToolCall(
            id: 'invalid-$toolId',
            tool: toolId,
            arguments: const <String, dynamic>{'event_id': 1},
          )),
          throwsA(isA<ToolCallValidationException>()),
        );
      }
      expect(
        buildStageSixToolDefinitions().map((item) => item.id),
        isNot(contains(CompetitionFitSkill.skillId)),
      );
      expect(
        competitionAdvisorAccountIndependentSkillIds,
        <String>{
          CompetitionCapabilityProfileSkill.skillId,
          ExplainCompetitionMatchesSkill.skillId,
          DraftAddCompetitionToPlanSkill.skillId,
        },
      );
    });

    test('studentProfile 支持审计存储值往返解析', () {
      expect(PersonalDataType.studentProfile.storageValue, 'student_profile');
      expect(
        PersonalDataTypeStorage.fromStorage('student_profile'),
        PersonalDataType.studentProfile,
      );
    });

    test('竞赛解释序列化只保留确定性解释字段且不泄露材料审核信息', () {
      final page = CompetitionMatchExplanationPage(
        profileReady: true,
        preferenceConfigured: true,
        items: <CompetitionMatchExplanationItem>[
          CompetitionMatchExplanationItem.fromEvent(
            CompetitionEvent(
              id: 7,
              title: '程序设计竞赛',
              personalizedScore: 82,
              recommendationTier: 'strong',
              fitReasons: const <String>['技能匹配'],
              competitionRating: 'A',
              schoolRecognitionStatus: 'recognized',
              timeStatus: 'confirmed',
              registrationTimeText: '2026-10',
            ),
          ),
        ],
        total: 1,
        fetchedAt: DateTime.utc(2026, 7, 20),
      );

      final json = const SkillResultSerializer().serialize(
        SkillResult<Object?>(
          value: page,
          status: SkillStatus.success,
          containsPersonalData: true,
        ),
      );

      expect(json, contains('"competition_rating":"A"'));
      expect(json, contains('"school_recognition_status":"recognized"'));
      for (final forbidden in <String>[
        'evidence_file_id',
        'verification_note',
        'verified_by',
        'file_path',
        'access_log',
        'personalized_score',
      ]) {
        expect(json, isNot(contains(forbidden)));
      }
    });
  });

  group('ToolPermissionManager', () {
    test('低敏感允许会话复用，中敏感强制降级为仅本次', () async {
      final prompt = _Prompt(ToolPermissionDecision.allowSession);
      final manager = ToolPermissionManager(
        prompt: prompt,
        accountKey: 'app-a::edu-a',
      );
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
      expect(
        await manager.authorize(_preview(SkillSensitivity.medium)),
        ToolPermissionDecision.allowOnce,
      );
      expect(prompt.count, 3);
    });

    test('会话授权按模型目标隔离且清空后失效', () async {
      final prompt = _Prompt(ToolPermissionDecision.allowSession);
      final manager = ToolPermissionManager(
        prompt: prompt,
        accountKey: 'app-a::edu-a',
      );

      await manager.authorize(_preview(SkillSensitivity.low));
      await manager.authorize(
        _preview(SkillSensitivity.low, destination: 'provider-b'),
      );
      expect(prompt.count, 2);

      manager.clearSession();
      await manager.authorize(_preview(SkillSensitivity.low));
      expect(prompt.count, 3);
    });
  });

  group('LocalToolLoop', () {
    test('第二轮请求会携带已完成的用户和助手历史', () async {
      final model = _ScriptedModel(
        const <ToolModelTurn>[ToolModelTurn.finalAnswer('继续回答')],
      );
      final outcome = await _loop(model: model).run(
        userMessage: '那第二项呢？',
        tools: buildStageSixToolDefinitions(),
        conversationHistory: const <ToolConversationMessage>[
          ToolConversationMessage(
            role: ToolMessageRole.user,
            content: '我想提升人工智能能力',
          ),
          ToolConversationMessage(
            role: ToolMessageRole.assistant,
            content: '可以先参加基础赛事。',
          ),
          ToolConversationMessage(
            role: ToolMessageRole.tool,
            content: '不得进入历史的原始 Tool Result',
          ),
        ],
      );

      expect(outcome.status, ToolLoopStatus.completed);
      expect(
        model.receivedMessages.map((item) => item.content),
        containsAllInOrder(<String>[
          '我想提升人工智能能力',
          '可以先参加基础赛事。',
          '那第二项呢？',
        ]),
      );
      expect(
        model.receivedMessages.map((item) => item.content),
        isNot(contains('不得进入历史的原始 Tool Result')),
      );
    });

    test('未绑定教务时公开竞赛搜索仍可执行', () async {
      final source = _CompetitionSearchSource();
      final model = _ScriptedModel(<ToolModelTurn>[
        ToolModelTurn.call(
          LocalToolCall(
            id: 'search-1',
            tool: CompetitionSearchSkill.skillId,
            arguments: const <String, dynamic>{'keyword': '人工智能'},
          ),
        ),
        const ToolModelTurn.finalAnswer('找到公开竞赛。'),
      ]);
      final outcome = await _loop(
        model: model,
        gateway: const UnavailablePersonalDataGateway(),
        registry: PersonalSkillRegistry(<PersonalSkill<dynamic, dynamic>>[
          CompetitionSearchSkill(source),
        ]),
      ).run(
        userMessage: '搜索人工智能竞赛',
        tools: buildStageSixToolDefinitions()
            .where((item) => item.id == CompetitionSearchSkill.skillId)
            .toList(),
      );

      expect(outcome.status, ToolLoopStatus.completed);
      expect(source.searches, 1);
    });

    test('未绑定教务时请求学业工具返回明确绑定说明', () async {
      final model = _ScriptedModel(<ToolModelTurn>[
        ToolModelTurn.call(_academicCall('academic-unavailable')),
      ]);
      final outcome = await _loop(
        model: model,
        gateway: const UnavailablePersonalDataGateway(),
      ).run(
        userMessage: '查看我的学业情况',
        tools: const <ToolDefinition>[],
        unavailableToolReasons: const <String, String>{
          AcademicOverviewSkill.skillId: '需要绑定教务后才能读取学业数据',
        },
      );

      expect(outcome.status, ToolLoopStatus.rejected);
      expect(outcome.warnings, <String>['需要绑定教务后才能读取学业数据']);
    });

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

    test('工具循环把模型推理上下文带入下一轮请求', () async {
      final model = _ScriptedModel(<ToolModelTurn>[
        ToolModelTurn.call(
          _academicCall('call-1'),
          assistantContent: '准备读取本地数据。',
          reasoningContent: '需要调用学业概览工具。',
        ),
        const ToolModelTurn.finalAnswer('已完成。'),
      ]);

      final outcome = await _loop(model: model).run(
        userMessage: '查看学业概览',
        tools: buildStageSixToolDefinitions(),
      );

      expect(outcome.status, ToolLoopStatus.completed);
      final assistant = model.receivedMessages.singleWhere(
        (message) =>
            message.role == ToolMessageRole.assistant &&
            message.toolCall != null,
      );
      expect(assistant.content, '准备读取本地数据。');
      expect(assistant.reasoningContent, '需要调用学业概览工具。');
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

    test('竞赛解释授权准确声明服务端确定性结果并排除政策推断', () async {
      final source = _ToolCompetitionMatchSource();
      final prompt = _Prompt(ToolPermissionDecision.allowOnce);
      final audit = _AuditSink();
      final model = _ScriptedModel(<ToolModelTurn>[
        ToolModelTurn.call(
          LocalToolCall(
            id: 'fit-1',
            tool: ExplainCompetitionMatchesSkill.skillId,
            arguments: const <String, dynamic>{},
          ),
        ),
        const ToolModelTurn.finalAnswer('竞赛适配完成。'),
      ]);
      final outcome = await _loop(
        model: model,
        audit: audit,
        prompt: prompt,
        registry: PersonalSkillRegistry(<PersonalSkill<dynamic, dynamic>>[
          ExplainCompetitionMatchesSkill(source),
        ]),
      ).run(
        userMessage: '我想参加人工智能竞赛',
        tools: buildStageSixToolDefinitions(),
      );

      expect(outcome.status, ToolLoopStatus.completed);
      final preview = prompt.lastPreview!;
      expect(
          preview.dataItems.single.dataType, PersonalDataType.studentProfile);
      expect(
        preview.dataItems.single.label,
        '平台已有的“适合我”确定性排序及匹配依据',
      );
      expect(preview.dataItems.single.label, isNot('公开检索结果'));
      expect(preview.excludedDataLabels,
          containsAll(<String>['证明材料、获奖核验备注和审核信息', '成绩、GPA、毕业和保研政策收益']));
      expect(preview.outputFields, contains('原有个性化分数、推荐档位和匹配理由'));
      expect(model.receivedMessages.last.content,
          contains('"contains_personal_data":true'));
      expect(audit.entries.single.dataTypes,
          const <PersonalDataType>{PersonalDataType.studentProfile});
      expect(source.reads, 1);
    });

    test('工具级授权元数据准确描述 GPA 和运动计划输入输出', () async {
      const source = DefaultToolPreviewMetadataSource();
      final gpa = await source.describe(
        const ToolPreviewRequest(
          toolId: AcademicGpaSkill.skillId,
          validatedInput: EmptyDeterministicInput(),
          dataTypes: <PersonalDataType>{PersonalDataType.academic},
        ),
      );
      expect(gpa.inputItems.single.label, contains('课程成绩'));
      expect(gpa.inputItems.single.label, isNot('最小化学业数据'));
      expect(gpa.outputFields, contains('GPA'));
      expect(gpa.excludedDataLabels, contains('教务密码'));

      final fitness = await source.describe(
        const ToolPreviewRequest(
          toolId: FitnessWeeklyPlanSkill.skillId,
          validatedInput: FitnessWeeklyPlanInput(
            heightMeters: 1.75,
            weightKg: 65,
            reportsDiscomfort: true,
          ),
          dataTypes: <PersonalDataType>{
            PersonalDataType.schedule,
            PersonalDataType.physical,
          },
        ),
      );
      expect(
        fitness.inputItems.map((item) => item.label),
        contains('用户主动填写的身高、体重、不适状态'),
      );
      expect(fitness.outputFields, contains('安全提示'));
      await expectLater(
        source.describe(
          const ToolPreviewRequest(
            toolId: 'unknown.tool',
            validatedInput: EmptyDeterministicInput(),
            dataTypes: <PersonalDataType>{},
          ),
        ),
        throwsStateError,
      );
    });

    test('全部 Tool 定义均有与数据权限一致的授权元数据', () async {
      const source = DefaultToolPreviewMetadataSource();
      const validator = LocalToolCallValidator();
      const dataTypesByTool = <String, Set<PersonalDataType>>{
        TodayScheduleSkill.skillId: <PersonalDataType>{
          PersonalDataType.schedule,
        },
        WeekScheduleSkill.skillId: <PersonalDataType>{
          PersonalDataType.schedule,
        },
        AcademicOverviewSkill.skillId: <PersonalDataType>{
          PersonalDataType.academic,
        },
        PhysicalOverviewSkill.skillId: <PersonalDataType>{
          PersonalDataType.physical,
        },
        ErkeOverviewSkill.skillId: <PersonalDataType>{
          PersonalDataType.erke,
        },
        CompetitionSearchSkill.skillId: <PersonalDataType>{},
        CompetitionCapabilityProfileSkill.skillId: <PersonalDataType>{
          PersonalDataType.studentProfile,
        },
        AcademicGpaSkill.skillId: <PersonalDataType>{
          PersonalDataType.academic,
        },
        AcademicCreditSummarySkill.skillId: <PersonalDataType>{
          PersonalDataType.academic,
        },
        AcademicFailureRiskSkill.skillId: <PersonalDataType>{
          PersonalDataType.academic,
        },
        GraduationReadinessSkill.skillId: <PersonalDataType>{
          PersonalDataType.academic,
          PersonalDataType.erke,
        },
        ExplainCompetitionMatchesSkill.skillId: <PersonalDataType>{
          PersonalDataType.studentProfile,
        },
        DraftAddCompetitionToPlanSkill.skillId: <PersonalDataType>{
          PersonalDataType.studentProfile,
        },
        FitnessWeeklyPlanSkill.skillId: <PersonalDataType>{
          PersonalDataType.schedule,
          PersonalDataType.physical,
        },
      };
      final definitions = buildStageSixToolDefinitions();
      expect(
        definitions.map((definition) => definition.id).toSet(),
        dataTypesByTool.keys.toSet(),
      );

      for (final definition in definitions) {
        final arguments = switch (definition.id) {
          CompetitionSearchSkill.skillId => <String, dynamic>{
              'keyword': '人工智能'
            },
          DraftAddCompetitionToPlanSkill.skillId => <String, dynamic>{
              'event_id': 1
            },
          _ => <String, dynamic>{},
        };
        final validated = validator.validate(
          LocalToolCall(
            id: 'preview-${definition.id}',
            tool: definition.id,
            arguments: arguments,
          ),
        );
        final metadata = await source.describe(
          ToolPreviewRequest(
            toolId: definition.id,
            validatedInput: validated.input,
            dataTypes: dataTypesByTool[definition.id]!,
          ),
        );
        expect(metadata.outputFields, isNotEmpty, reason: definition.id);
        expect(metadata.excludedDataLabels, isNotEmpty, reason: definition.id);
      }

      await expectLater(
        source.describe(
          const ToolPreviewRequest(
            toolId: AcademicGpaSkill.skillId,
            validatedInput: EmptyDeterministicInput(),
            dataTypes: <PersonalDataType>{PersonalDataType.schedule},
          ),
        ),
        throwsStateError,
      );
    });

    test('账号代际变化会在读取确定性竞赛结果前取消', () async {
      var generation = 1;
      final source = _ToolCompetitionMatchSource();
      final model = _ScriptedModel(
        <ToolModelTurn>[
          ToolModelTurn.call(LocalToolCall(
            id: 'fit-cancel',
            tool: ExplainCompetitionMatchesSkill.skillId,
            arguments: const <String, dynamic>{},
          )),
        ],
        onTurn: () => generation++,
      );
      final outcome = await _loop(
        model: model,
        generation: () => generation,
        registry: PersonalSkillRegistry(<PersonalSkill<dynamic, dynamic>>[
          ExplainCompetitionMatchesSkill(source),
        ]),
      ).run(
        userMessage: '推荐竞赛',
        tools: buildStageSixToolDefinitions(),
      );

      expect(outcome.status, ToolLoopStatus.cancelled);
      expect(model.cancelled, isTrue);
      expect(source.reads, 0);
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
  PersonalDataGateway? gateway,
  _AuditSink? audit,
  _Prompt? prompt,
  PersonalSkillRegistry? registry,
  ToolPermissionDecision decision = ToolPermissionDecision.allowOnce,
  int Function()? generation,
  Duration timeout = const Duration(seconds: 1),
}) {
  final dataGateway = gateway ?? _Gateway();
  return LocalToolLoop(
    registry: registry ??
        PersonalSkillRegistry(<PersonalSkill<dynamic, dynamic>>[
          AcademicOverviewSkill(),
        ]),
    executionContext: SkillExecutionContext(
      personalDataGateway: dataGateway,
      clock: () => DateTime.utc(2026, 7, 20),
    ),
    model: model,
    permissionManager: ToolPermissionManager(
      prompt: prompt ?? _Prompt(decision),
      accountKey: 'app-a::edu-a',
    ),
    auditSink: audit ?? _AuditSink(),
    accountGeneration: generation ?? () => 1,
    skillTimeout: timeout,
  );
}

class _CompetitionSearchSource implements CompetitionSearchSource {
  int searches = 0;

  @override
  Future<CompetitionSearchPage> search(CompetitionSearchInput input) async {
    searches++;
    return CompetitionSearchPage(
      events: const [],
      total: 0,
      fetchedAt: DateTime.utc(2026, 7, 21),
    );
  }
}

LocalToolCall _academicCall(String id) => LocalToolCall(
      id: id,
      tool: AcademicOverviewSkill.skillId,
      arguments: const <String, dynamic>{},
    );

ToolPermissionPreview _preview(
  SkillSensitivity sensitivity, {
  String destination = 'test',
}) =>
    ToolPermissionPreview(
      toolId: 'test',
      sensitivity: sensitivity,
      providerKind: AIModelProviderKind.openAICompatible,
      destination: destination,
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
  ToolPermissionPreview? lastPreview;

  @override
  Future<ToolPermissionDecision> request(ToolPermissionPreview preview) async {
    count++;
    lastPreview = preview;
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

class _ToolCompetitionMatchSource implements CompetitionMatchExplanationSource {
  int reads = 0;

  @override
  Future<CompetitionMatchExplanationPage> load() async {
    reads++;
    return CompetitionMatchExplanationPage(
      profileReady: true,
      preferenceConfigured: true,
      items: <CompetitionMatchExplanationItem>[
        CompetitionMatchExplanationItem.fromEvent(
          CompetitionEvent(
            id: 1,
            title: '人工智能竞赛',
            personalizedScore: 75,
            recommendationTier: 'recommended',
            fitReasons: const <String>['方向匹配'],
          ),
        ),
      ],
      total: 1,
      fetchedAt: DateTime.utc(2026, 7, 20),
    );
  }
}
