import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/ai_capabilities.dart';
import 'package:shenliyuan/models/ai_chat_message.dart';
import 'package:shenliyuan/models/ai_conversation.dart';
import 'package:shenliyuan/models/ai_quota.dart';
import 'package:shenliyuan/models/ai_run.dart';
import 'package:shenliyuan/models/ai_run_event.dart';
import 'package:shenliyuan/models/agent_context.dart';
import 'package:shenliyuan/providers/ai_assistant_provider.dart';
import 'package:shenliyuan/services/ai_assistant_service.dart';

AiCapabilities _p0Capabilities() {
  return const AiCapabilities(
    enabled: true,
    accessAllowed: true,
    internalTestOnly: true,
    chatEnabled: false,
    phase: 'p0',
    features: AiFeatures(policyRag: false, scheduleWindows: false),
    quota: AiQuota(limit: 3, remaining: 3, windowSeconds: 3600),
    maxMessageChars: 20,
  );
}

AiCapabilities _availableCapabilities() {
  return const AiCapabilities(
    enabled: true,
    accessAllowed: true,
    internalTestOnly: false,
    chatEnabled: true,
    phase: 'p2',
    features: AiFeatures(policyRag: true, scheduleWindows: false),
    quota: AiQuota(limit: 3, remaining: 3, windowSeconds: 3600),
    maxMessageChars: 20,
  );
}

void main() {
  test('常用问题库不少于 20 条且问题符合输入长度限制', () {
    expect(aiCommonQuestionBank.length, greaterThanOrEqualTo(20));
    expect(
      aiCommonQuestionBank.map((item) => item.question).toSet().length,
      aiCommonQuestionBank.length,
    );
    expect(
      aiCommonQuestionBank.every(
        (item) => aiVisibleCharacterCount(item.question) <= 20,
      ),
      isTrue,
    );
  });

  test('常用问题随机展示四条且换一批不与当前批次重复', () {
    final provider = AiAssistantProvider(
      AiAssistantService(Dio()),
      initialCapabilities: const AiCapabilities(
        enabled: true,
        accessAllowed: true,
        internalTestOnly: false,
        chatEnabled: true,
        phase: 'p2',
        features: AiFeatures(policyRag: true, scheduleWindows: false),
        quota: AiQuota(limit: 3, remaining: 3, windowSeconds: 3600),
        maxMessageChars: 20,
      ),
      random: Random(7),
    );
    addTearDown(provider.dispose);

    final firstBatch =
        provider.quickPrompts.map((item) => item.question).toSet();
    expect(firstBatch, hasLength(4));

    provider.refreshQuickPrompts();
    final secondBatch =
        provider.quickPrompts.map((item) => item.question).toSet();
    expect(secondBatch, hasLength(4));
    expect(firstBatch.intersection(secondBatch), isEmpty);
  });

  test('问答未开放时初始化不请求历史会话', () async {
    final requestedPaths = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requestedPaths.add(options.path);
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'enabled': true,
                'access_allowed': true,
                'chat_enabled': false,
                'phase': 'p0',
                'features': <String, dynamic>{},
                'quota': {
                  'limit': 3,
                  'remaining': 3,
                  'window_seconds': 3600,
                },
                'max_message_chars': 20,
              },
            ),
          );
        },
      ),
    );
    final provider = AiAssistantProvider(
      AiAssistantService(dio),
      initialCapabilities: _p0Capabilities(),
    );
    addTearDown(provider.dispose);

    await provider.initialize();

    expect(requestedPaths, const ['/ai/capabilities']);
    expect(provider.error, isNull);
  });

  test('能力刷新为已开放后初始化正常请求历史会话', () async {
    final requestedPaths = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requestedPaths.add(options.path);
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: options.path == '/ai/capabilities'
                  ? {
                      'enabled': true,
                      'access_allowed': true,
                      'chat_enabled': true,
                      'phase': 'p2',
                      'features': {
                        'policy_rag': true,
                        'schedule_windows': false,
                      },
                      'quota': {
                        'limit': 3,
                        'remaining': 3,
                        'window_seconds': 3600,
                      },
                      'max_message_chars': 20,
                    }
                  : {'conversations': <Map<String, dynamic>>[]},
            ),
          );
        },
      ),
    );
    final provider = AiAssistantProvider(
      AiAssistantService(dio),
      initialCapabilities: _p0Capabilities(),
    );
    addTearDown(provider.dispose);

    await provider.initialize();

    expect(
      requestedPaths,
      const ['/ai/capabilities', '/ai/conversations'],
    );
    expect(provider.error, isNull);
  });

  test('账号 A 的会话列表迟到时不覆盖账号 B 的状态', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
    final firstListStarted = Completer<void>();
    final secondListStarted = Completer<void>();
    final firstListGate = Completer<void>();
    final secondListGate = Completer<void>();
    var listIndex = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/ai/capabilities') {
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'enabled': true,
                  'access_allowed': true,
                  'chat_enabled': true,
                  'phase': 'p2',
                  'features': {'policy_rag': true},
                  'quota': {
                    'limit': 3,
                    'remaining': 3,
                    'window_seconds': 3600,
                  },
                  'max_message_chars': 20,
                },
              ),
            );
            return;
          }
          if (options.path != '/ai/conversations') {
            handler.reject(
              DioException(
                requestOptions: options,
                message: 'unexpected ${options.path}',
              ),
            );
            return;
          }
          final index = ++listIndex;
          final gate = index == 1 ? firstListGate : secondListGate;
          if (index == 1) {
            firstListStarted.complete();
          } else {
            secondListStarted.complete();
          }
          gate.future.then((_) {
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'conversations': [
                    {
                      'id': index == 1 ? 'account-a' : 'account-b',
                      'title': index == 1 ? 'A 的会话' : 'B 的会话',
                    },
                  ],
                },
              ),
            );
          });
        },
      ),
    );
    final provider = AiAssistantProvider(
      AiAssistantService(dio),
      initialCapabilities: _availableCapabilities(),
    );
    addTearDown(provider.dispose);

    provider.resetForAccountChange(accountId: 1, sessionGeneration: 1);
    final staleBootstrap = provider.retryBootstrap();
    await firstListStarted.future;

    provider.resetForAccountChange(accountId: 2, sessionGeneration: 2);
    final currentBootstrap = provider.retryBootstrap();
    await secondListStarted.future;
    firstListGate.complete();
    await staleBootstrap;

    expect(provider.loading, isTrue);
    expect(provider.loadingConversations, isTrue);
    expect(provider.conversations, isEmpty);
    expect(provider.error, isNull);

    secondListGate.complete();
    await currentBootstrap;

    expect(provider.loading, isFalse);
    expect(provider.loadingConversations, isFalse);
    expect(provider.conversations.single.id, 'account-b');
    expect(provider.error, isNull);
  });

  test('账号 A 的会话详情错误不会写入账号 B', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
    final requestStarted = Completer<void>();
    final responseGate = Completer<void>();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requestStarted.complete();
          responseGate.future.then((_) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                message: 'account A offline',
              ),
            );
          });
        },
      ),
    );
    final provider = AiAssistantProvider(
      AiAssistantService(dio),
      initialCapabilities: _availableCapabilities(),
    );
    addTearDown(provider.dispose);

    provider.resetForAccountChange(accountId: 1, sessionGeneration: 1);
    final staleOpen = provider.openConversation('account-a-conversation');
    await requestStarted.future;

    provider.resetForAccountChange(accountId: 2, sessionGeneration: 2);
    responseGate.complete();
    await staleOpen;

    expect(provider.loading, isFalse);
    expect(provider.conversationId, isNull);
    expect(provider.messages, isEmpty);
    expect(provider.conversations, isEmpty);
    expect(provider.error, isNull);
  });

  test('账号切换会主动取消服务器 Agent SSE 并清空 Run', () async {
    final events = StreamController<Uint8List>();
    addTearDown(events.close);
    final eventRequestStarted = Completer<void>();
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'POST' && options.path == '/ai/runs') {
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 202,
                data: const {
                  'run': {
                    'id': 'run-a',
                    'conversation_id': 'conversation-a',
                    'state': 'created',
                  },
                  'duplicate': false,
                },
              ),
            );
            return;
          }
          if (options.method == 'GET' &&
              options.path == '/ai/runs/run-a/events') {
            eventRequestStarted.complete();
            handler.resolve(
              Response<ResponseBody>(
                requestOptions: options,
                statusCode: 200,
                data: ResponseBody(events.stream, 200),
              ),
            );
            return;
          }
          handler.reject(
            DioException(
              requestOptions: options,
              message: 'unexpected ${options.method} ${options.path}',
            ),
          );
        },
      ),
    );
    final provider = AiAssistantProvider(
      AiAssistantService(dio),
      initialCapabilities: _availableCapabilities(),
    );
    addTearDown(provider.dispose);

    provider.resetForAccountChange(accountId: 1, sessionGeneration: 1);
    expect(provider.submit('奖学金'), AiSubmitResult.accepted);
    await eventRequestStarted.future;
    for (var index = 0; index < 10 && !events.hasListener; index++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(events.hasListener, isTrue);

    provider.resetForAccountChange(accountId: 2, sessionGeneration: 2);
    for (var index = 0; index < 100 && events.hasListener; index++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(events.hasListener, isFalse);
    expect(provider.messages, isEmpty);
    expect(provider.conversationId, isNull);
    expect(provider.currentRun, isNull);
    expect(provider.connectionState, AiConnectionState.idle);
  });

  test('换行归一为空格并按 grapheme cluster 计数', () {
    expect(normalizeAiMessage('  奖学金\n怎么申请  '), '奖学金 怎么申请');
    expect(aiVisibleCharacterCount('👨‍👩‍👧‍👦'), 1);
  });

  test('Hy3 能力只进入固定快捷入口，不混入轮换问题池', () {
    final available = AiAssistantProvider(
      AiAssistantService(Dio()),
      initialCapabilities: const AiCapabilities(
        enabled: true,
        accessAllowed: true,
        internalTestOnly: false,
        chatEnabled: true,
        phase: 'p2',
        features: AiFeatures(
          policyRag: false,
          scheduleWindows: false,
          hy3CompetitionCompare: true,
          hy3AcademicAnalysis: true,
          hy3WeekPlan: true,
        ),
        quota: AiQuota(limit: 3, remaining: 3, windowSeconds: 3600),
        maxMessageChars: 20,
      ),
    );
    addTearDown(available.dispose);

    expect(available.capabilities?.features.hy3CompetitionCompare, isTrue);
    expect(available.capabilities?.features.hy3AcademicAnalysis, isTrue);
    expect(available.capabilities?.features.hy3WeekPlan, isTrue);
    expect(
      available.quickPrompts.map((item) => item.question),
      isNot(contains('对比适合我的竞赛')),
    );
    expect(
      available.quickPrompts.map((item) => item.question),
      isNot(contains('分析我的学业情况')),
    );
    expect(
      available.quickPrompts.map((item) => item.question),
      isNot(contains('制定本周学习计划')),
    );

    final unavailable = AiAssistantProvider(
      AiAssistantService(Dio()),
      initialCapabilities: _p0Capabilities(),
    );
    addTearDown(unavailable.dispose);
    final unavailableQuestions =
        unavailable.quickPrompts.map((item) => item.question);
    expect(unavailableQuestions, isNot(contains('对比适合我的竞赛')));
    expect(unavailableQuestions, isNot(contains('分析我的学业情况')));
    expect(unavailableQuestions, isNot(contains('制定本周学习计划')));
  });

  test('P0 不构造假消息，也不会发起真实请求', () {
    final provider = AiAssistantProvider(
      AiAssistantService(Dio()),
      initialCapabilities: _p0Capabilities(),
    );

    expect(provider.submit('奖学金'), AiSubmitResult.unavailable);
    expect(provider.messages, isEmpty);
    expect(provider.error, contains('基础设施测试中'));
  });

  test('500 个可见字符允许，501 个会在发送前拒绝', () {
    final provider = AiAssistantProvider(
      AiAssistantService(Dio()),
      initialCapabilities: AiCapabilities.fromJson(const {
        'enabled': true,
        'access_allowed': true,
        'chat_enabled': false,
        'max_message_chars': 500,
        'quota': {
          'limit': 3,
          'remaining': 3,
          'window_seconds': 3600,
        },
      }),
    );

    expect(
      provider.submit(List.filled(500, '一').join()),
      AiSubmitResult.unavailable,
    );
    expect(
      provider.submit(List.filled(501, '一').join()),
      AiSubmitResult.tooLong,
    );
  });

  test('不限次数账号不会被为零的兼容配额拦截', () {
    final provider = AiAssistantProvider(
      AiAssistantService(Dio()),
      initialCapabilities: const AiCapabilities(
        enabled: true,
        accessAllowed: true,
        internalTestOnly: true,
        chatEnabled: false,
        phase: 'p0',
        features: AiFeatures(policyRag: false, scheduleWindows: false),
        quota: AiQuota(
          limit: 3,
          remaining: 0,
          windowSeconds: 3600,
          unlimited: true,
        ),
        maxMessageChars: 20,
      ),
    );

    expect(provider.submit('奖学金'), AiSubmitResult.unavailable);
  });

  test('SSE 回放重复 seq 不会重复拼接答案', () {
    final provider = AiAssistantProvider(
      AiAssistantService(Dio()),
      initialCapabilities: const AiCapabilities(
        enabled: true,
        accessAllowed: true,
        internalTestOnly: false,
        chatEnabled: true,
        phase: 'p2',
        features: AiFeatures(policyRag: true, scheduleWindows: false),
        quota: AiQuota(limit: 3, remaining: 2, windowSeconds: 3600),
        maxMessageChars: 20,
      ),
    );
    addTearDown(provider.dispose);

    provider.applyRunEvent(const AiRunEvent(
      runId: 'run-1',
      seq: 1,
      type: AiRunEventType.delta,
      text: '奖学金',
    ));
    provider.applyRunEvent(const AiRunEvent(
      runId: 'run-1',
      seq: 1,
      type: AiRunEventType.delta,
      text: '奖学金',
    ));
    provider.applyRunEvent(const AiRunEvent(
      runId: 'run-1',
      seq: 2,
      type: AiRunEventType.checkpoint,
      text: '奖学金评定规则见学生手册。',
    ));

    expect(provider.streamedText, '奖学金评定规则见学生手册。');
    expect(provider.messages.single.content, '奖学金评定规则见学生手册。');
  });

  test('普通 Tool 事件不会伪造授权卡，真实授权事件才设置 pendingConsent', () {
    final provider = AiAssistantProvider(
      AiAssistantService(Dio()),
      initialCapabilities: const AiCapabilities(
        enabled: true,
        accessAllowed: true,
        internalTestOnly: false,
        chatEnabled: true,
        phase: 'p2',
        features: AiFeatures(policyRag: true, scheduleWindows: false),
        quota: AiQuota(limit: 3, remaining: 2, windowSeconds: 3600),
        maxMessageChars: 20,
      ),
    );
    addTearDown(provider.dispose);

    provider.applyRunEvent(const AiRunEvent(
      runId: 'run-consent',
      seq: 1,
      type: AiRunEventType.toolExecuting,
    ));
    expect(provider.pendingConsent, isNull);

    provider.applyRunEvent(const AiRunEvent(
      runId: 'run-consent',
      seq: 2,
      type: AiRunEventType.consentRequired,
      consentScope: 'ai_device_cache_access',
    ));
    expect(provider.pendingConsent?.consentScope, 'ai_device_cache_access');
  });

  test('deviceWaiting SSE 立即主动补拉设备任务且 Run 保持运行中', () async {
    var syncCalls = 0;
    final provider = AiAssistantProvider(
      AiAssistantService(Dio()),
      initialCapabilities: _availableCapabilities(),
      deviceToolSync: () async {
        syncCalls++;
      },
    );
    addTearDown(provider.dispose);

    provider.applyRunEvent(const AiRunEvent(
      runId: 'run-device',
      seq: 1,
      type: AiRunEventType.deviceWaiting,
      datasets: ['grades', 'academic_situation', 'credit_requirements'],
    ));
    await Future<void>.delayed(Duration.zero);

    expect(syncCalls, 1);
    expect(provider.isRunning, isTrue);
    expect(provider.agentFlowCompleted, isFalse);
  });

  test('风险分析的二课可选动作会保留为客户端入口', () {
    final provider = AiAssistantProvider(
      AiAssistantService(Dio()),
      initialCapabilities: _availableCapabilities(),
    );
    addTearDown(provider.dispose);

    provider.applyRunEvent(AiRunEvent.fromJson({
      'run_id': 'run-erke',
      'seq': 1,
      'type': 'tool.completed',
      'payload': {
        'tool_name': 'academic.get_risk_analysis',
        'optional_actions': ['update_erke'],
      },
    }));

    expect(provider.hasOptionalErkeUpdate, isTrue);
  });

  test('完成事件中的笼统来源标记会从 Run 来源接口恢复引用', () async {
    final requestedPaths = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requestedPaths.add(options.path);
          if (options.path == '/ai/runs/run-1/sources') {
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'sources': [
                    {
                      'type': 'policy',
                      'primary_chunk_id': 18,
                      'document_id': 4,
                      'title': '奖助学金管理办法',
                    },
                  ],
                },
              ),
            );
            return;
          }
          if (options.path == '/ai/capabilities') {
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'enabled': true,
                  'access_allowed': true,
                  'chat_enabled': true,
                  'phase': 'p2',
                  'features': {'policy_rag': true},
                  'quota': {
                    'limit': 3,
                    'remaining': 2,
                    'window_seconds': 3600,
                  },
                  'max_message_chars': 20,
                },
              ),
            );
            return;
          }
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: {'conversations': <Map<String, dynamic>>[]},
            ),
          );
        },
      ),
    );
    final provider = AiAssistantProvider(
      AiAssistantService(dio),
      initialCapabilities: const AiCapabilities(
        enabled: true,
        accessAllowed: true,
        internalTestOnly: false,
        chatEnabled: true,
        phase: 'p2',
        features: AiFeatures(policyRag: true, scheduleWindows: false),
        quota: AiQuota(limit: 3, remaining: 2, windowSeconds: 3600),
        maxMessageChars: 20,
      ),
    );
    addTearDown(provider.dispose);

    provider.applyRunEvent(const AiRunEvent(
      runId: 'run-1',
      seq: 1,
      type: AiRunEventType.delta,
      text: '请参考 [来源]',
    ));
    provider.applyRunEvent(const AiRunEvent(
      runId: 'run-1',
      seq: 2,
      type: AiRunEventType.completed,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final assistant = provider.messages.singleWhere(
      (message) => message.role == AiMessageRole.assistant,
    );
    expect(assistant.sourceRecoveryState, AiSourceRecoveryState.loaded);
    expect(assistant.sources.single.title, '奖助学金管理办法');
    expect(requestedPaths, contains('/ai/runs/run-1/sources'));
  });

  test('历史会话保留消息内政策来源，并通过聚合接口补个人证据', () async {
    final requestedPaths = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requestedPaths.add(options.path);
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'conversation': {
                  'id': 'conversation-1',
                  'title': '奖学金咨询',
                },
                'messages': [
                  {
                    'id': 'message-1',
                    'conversation_id': 'conversation-1',
                    'run_id': 'run-1',
                    'role': 'assistant',
                    'content': '请参考 [chunk:18]',
                    'sources': [
                      {
                        'type': 'policy',
                        'primary_chunk_id': 18,
                        'title': '奖助学金管理办法',
                      },
                    ],
                  },
                ],
              },
            ),
          );
        },
      ),
    );
    final provider = AiAssistantProvider(
      AiAssistantService(dio),
      initialCapabilities: const AiCapabilities(
        enabled: true,
        accessAllowed: true,
        internalTestOnly: false,
        chatEnabled: true,
        phase: 'p2',
        features: AiFeatures(policyRag: true, scheduleWindows: false),
        quota: AiQuota(limit: 3, remaining: 2, windowSeconds: 3600),
        maxMessageChars: 20,
      ),
    );
    addTearDown(provider.dispose);

    await provider.openConversation('conversation-1');

    expect(provider.messages.single.sources.single.title, '奖助学金管理办法');
    expect(requestedPaths, [
      '/ai/conversations/conversation-1',
      '/ai/runs/run-1/sources',
    ]);
  });

  test('输出达到长度上限时明确提示回答不完整', () {
    final provider = AiAssistantProvider(
      AiAssistantService(Dio()),
      initialCapabilities: const AiCapabilities(
        enabled: true,
        accessAllowed: true,
        internalTestOnly: false,
        chatEnabled: true,
        phase: 'p2',
        features: AiFeatures(policyRag: true, scheduleWindows: false),
        quota: AiQuota(limit: 3, remaining: 2, windowSeconds: 3600),
        maxMessageChars: 20,
      ),
    );
    addTearDown(provider.dispose);

    provider.applyRunEvent(const AiRunEvent(
      runId: 'run-length',
      seq: 1,
      type: AiRunEventType.delta,
      text: '补考比例差异',
    ));
    provider.applyRunEvent(const AiRunEvent(
      runId: 'run-length',
      seq: 2,
      type: AiRunEventType.failed,
      errorCode: 'output_limit_reached',
      retryable: true,
    ));

    expect(provider.error, '回答达到长度上限，未完整生成，请重试');
    expect(provider.messages.single.status.name, 'failed');
  });

  test('校园 AI 错误提示包含可执行的下一步', () {
    const cases = <String, String>{
      'personal_context_unavailable': '暂时没有可核验的学业数据，请先刷新成绩和学分后重试',
      'academic_snapshot_corrupted': '学业数据校验失败，请刷新教务数据后重试',
      'tool_call_limit': '本次分析步骤过多，请一次只问一个问题后重试',
      'external_mcp_timeout': '学业分析服务响应超时，请稍后重试',
      'external_mcp_invalid_result': '学业分析结果校验失败，请稍后重试',
      'provider_unavailable': '回答服务暂时不可用，请稍后重试',
      'provider_request_rejected': '回答服务暂时未接受本次请求，请重试',
      'provider_model_unavailable': '当前回答模型暂不可用，管理员需要检查服务配置',
      'rate_limited': '当前请求较多，请稍后重试',
    };

    var seq = 0;
    for (final entry in cases.entries) {
      final provider = AiAssistantProvider(
        AiAssistantService(Dio()),
        initialCapabilities: const AiCapabilities(
          enabled: true,
          accessAllowed: true,
          internalTestOnly: false,
          chatEnabled: true,
          phase: 'p2',
          features: AiFeatures(policyRag: true, scheduleWindows: false),
          quota: AiQuota(limit: 3, remaining: 2, windowSeconds: 3600),
          maxMessageChars: 20,
        ),
      );
      addTearDown(provider.dispose);
      provider.applyRunEvent(AiRunEvent(
        runId: 'error-${seq++}',
        seq: 1,
        type: AiRunEventType.failed,
        errorCode: entry.key,
        retryable: true,
      ));
      expect(provider.error, entry.value, reason: entry.key);
    }
  });

  test('SSE 断流且 Run 生成中时进入恢复态并继续回放', () async {
    final service = _FakeStreamingAiService();
    service.streamScripts.add((controller) {
      controller.add(const AiRunEvent(
        runId: 'run-recovery',
        seq: 1,
        type: AiRunEventType.started,
      ));
      controller.add(const AiRunEvent(
        runId: 'run-recovery',
        seq: 2,
        type: AiRunEventType.delta,
        text: '根据',
      ));
      controller.addError(StateError('sse reset'));
      unawaited(controller.close());
    });
    service.streamScripts.add((controller) {
      controller.add(const AiRunEvent(
        runId: 'run-recovery',
        seq: 3,
        type: AiRunEventType.delta,
        text: '成绩',
      ));
      controller.add(const AiRunEvent(
        runId: 'run-recovery',
        seq: 4,
        type: AiRunEventType.completed,
      ));
      unawaited(controller.close());
    });
    final provider = AiAssistantProvider(
      service,
      initialCapabilities: _availableCapabilities(),
      reconnectBackoff: const [Duration(milliseconds: 1)],
      random: Random(7),
    );
    addTearDown(provider.dispose);

    expect(provider.submit('我现在的成绩如何'), AiSubmitResult.accepted);

    await _waitUntil(() => provider.isReconnecting);
    expect(provider.error, isNull);
    expect(provider.streamedText, '根据');

    await _waitUntil(
        () => provider.connectionState == AiConnectionState.completed);
    expect(provider.error, isNull);
    expect(provider.streamedText, '根据成绩');
    expect(service.lastEventIds, const [0, 2]);
  });

  test('Run 已失败时恢复循环直接落败且不提示连接中断', () async {
    final service = _FakeStreamingAiService();
    service.streamScripts.add((controller) {
      controller.addError(StateError('sse reset'));
      unawaited(controller.close());
    });
    service.getRunOverride = const AiRun(
      id: 'run-recovery',
      conversationId: 'conversation-1',
      state: 'failed',
      lastEventSeq: 0,
      errorCode: 'provider_unavailable',
    );
    final provider = AiAssistantProvider(
      service,
      initialCapabilities: _availableCapabilities(),
      reconnectBackoff: const [Duration(milliseconds: 1)],
      random: Random(7),
    );
    addTearDown(provider.dispose);

    expect(provider.submit('我现在的成绩如何'), AiSubmitResult.accepted);

    await _waitUntil(
        () => provider.connectionState == AiConnectionState.failed);
    expect(provider.error, '回答服务暂时不可用，请稍后重试');
    expect(service.lastEventIds, hasLength(1));
  });

  test('多次断流期间非终态永不显示连接中断', () async {
    final service = _FakeStreamingAiService();
    for (var i = 0; i < 3; i++) {
      service.streamScripts.add((controller) {
        controller.add(AiRunEvent(
          runId: 'run-recovery',
          seq: i * 2 + 1,
          type: AiRunEventType.delta,
          text: '段$i',
        ));
        controller.addError(StateError('reset $i'));
        unawaited(controller.close());
      });
    }
    service.streamScripts.add((controller) {
      controller.add(const AiRunEvent(
        runId: 'run-recovery',
        seq: 7,
        type: AiRunEventType.completed,
      ));
      unawaited(controller.close());
    });
    final provider = AiAssistantProvider(
      service,
      initialCapabilities: _availableCapabilities(),
      reconnectBackoff: const [Duration(milliseconds: 1)],
      random: Random(7),
    );
    addTearDown(provider.dispose);
    final observedErrors = <List<String?>>[];
    provider.addListener(() => observedErrors.add(<String?>[provider.error]));

    expect(provider.submit('我现在的成绩如何'), AiSubmitResult.accepted);

    await _waitUntil(
        () => provider.connectionState == AiConnectionState.completed);
    expect(provider.error, isNull);
    expect(provider.streamedText, '段0段1段2');
    expect(service.lastEventIds, const [0, 1, 3, 5]);
    expect(
      observedErrors
          .expand((element) => element)
          .whereType<String>()
          .where((text) => text.contains('连接已中断')),
      isEmpty,
    );
  });
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待状态超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

class _FakeStreamingAiService extends AiAssistantService {
  _FakeStreamingAiService() : super(Dio());

  AiRun run = const AiRun(
    id: 'run-recovery',
    conversationId: 'conversation-1',
    state: 'generating',
    lastEventSeq: 0,
  );
  AiRun? getRunOverride;
  final List<void Function(StreamController<AiRunEvent>)> streamScripts = [];
  final List<int> lastEventIds = <int>[];

  @override
  Future<AiRunCreation> createRun({
    required String conversationId,
    required String clientRequestId,
    required String message,
    AgentLaunchContext? launchContext,
  }) async {
    return AiRunCreation(run: run, duplicate: false);
  }

  @override
  Future<AiRun> getRun(String runId) async {
    return getRunOverride ?? run;
  }

  @override
  Stream<AiRunEvent> streamRunEvents(String runId, {int lastEventId = 0}) {
    lastEventIds.add(lastEventId);
    final controller = StreamController<AiRunEvent>();
    if (streamScripts.isNotEmpty) {
      streamScripts.removeAt(0)(controller);
    }
    return controller.stream;
  }

  @override
  Future<AiRunSources> getRunSources(String runId) async {
    return const AiRunSources();
  }

  @override
  Future<AiCapabilities> getCapabilities() async {
    return _availableCapabilities();
  }

  @override
  Future<List<AiConversation>> listConversations() async {
    return const [];
  }

  @override
  Future<void> recordRunSignal({
    required String runId,
    required String signal,
  }) async {}
}
