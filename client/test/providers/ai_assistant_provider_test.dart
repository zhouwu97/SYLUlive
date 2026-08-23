import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/ai_capabilities.dart';
import 'package:shenliyuan/models/ai_chat_message.dart';
import 'package:shenliyuan/models/ai_quota.dart';
import 'package:shenliyuan/models/ai_run_event.dart';
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
}
