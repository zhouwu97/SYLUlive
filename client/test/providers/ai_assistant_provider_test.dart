import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/ai_capabilities.dart';
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
  test('换行归一为空格并按 grapheme cluster 计数', () {
    expect(normalizeAiMessage('  奖学金\n怎么申请  '), '奖学金 怎么申请');
    expect(aiVisibleCharacterCount('👨‍👩‍👧‍👦'), 1);
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

  test('20 个可见字符允许，21 个会在发送前拒绝', () {
    final provider = AiAssistantProvider(
      AiAssistantService(Dio()),
      initialCapabilities: _p0Capabilities(),
    );

    expect(
      provider.submit(List.filled(20, '一').join()),
      AiSubmitResult.unavailable,
    );
    expect(
      provider.submit(List.filled(21, '一').join()),
      AiSubmitResult.tooLong,
    );
  });

  test('无限配额账号不会被 remaining=0 错误拦截', () {
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

    expect(provider.submit('测试问题'), AiSubmitResult.unavailable);
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

  test('个人数据证据去重且等待状态使用真实设备文案', () {
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
    final evidence = AiRunEvent.parseSse(
      '{"run_id":"run-1","seq":1,"type":"personal_data.evidence",'
      '"payload":{"evidence":[{"source":"server_snapshot",'
      '"dataset":"grades","fetched_at":"2026-07-25T09:20:00Z"}]}}',
    );

    provider.applyRunEvent(evidence);
    provider.applyRunEvent(AiRunEvent.parseSse(
      '{"run_id":"run-1","seq":2,"type":"personal_data.evidence",'
      '"payload":{"evidence":[{"source":"server_snapshot",'
      '"dataset":"grades","fetched_at":"2026-07-25T09:20:00Z"}]}}',
    ));
    provider.applyRunEvent(const AiRunEvent(
      runId: 'run-1',
      seq: 3,
      type: AiRunEventType.deviceWaiting,
      datasets: ['schedule'],
    ));

    expect(provider.messages, hasLength(1));
    expect(provider.messages.single.personalDataEvidence, hasLength(1));
    expect(provider.friendlyRunStatus, '正在请求你的手机读取本地课表');
  });

  test('收到设备等待事件后立即触发设备任务补拉', () async {
    var syncCount = 0;
    final provider = AiAssistantProvider(
      AiAssistantService(Dio()),
      initialCapabilities: _p0Capabilities(),
      deviceToolSync: () async => syncCount += 1,
    );
    addTearDown(provider.dispose);

    provider.applyRunEvent(const AiRunEvent(
      runId: 'run-device-waiting',
      seq: 1,
      type: AiRunEventType.deviceWaiting,
      datasets: ['grades'],
    ));
    await pumpEventQueue();

    expect(syncCount, 1);
  });

  test('手动重新发送复用原 client_request_id', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
    final requestIds = <String>[];
    var attempts = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/ai/capabilities') {
            handler.reject(DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
            ));
            return;
          }
          attempts++;
          requestIds
              .add((options.data as Map)['client_request_id'] as String);
          // 两次创建都失败：第一次触发内部自动重试，随后由用户手动重试。
          handler.reject(DioException(
            requestOptions: options,
            type: DioExceptionType.connectionTimeout,
          ));
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

    expect(provider.submit('挂科了怎么办'), AiSubmitResult.accepted);
    // 服务层的自动重试有 400ms 退避，必须等待真实时间而不是只排空微任务队列。
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await pumpEventQueue();

    expect(provider.canRetry, isTrue, reason: '网络失败必须可重试');
    expect(provider.error, contains('连接服务器超时'));
    final beforeRetry = requestIds.length;
    expect(beforeRetry, 2, reason: '服务层已按同一 ID 自动重试一次');

    expect(provider.retryLast(), AiSubmitResult.accepted);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await pumpEventQueue();

    expect(requestIds.length, greaterThan(beforeRetry));
    // 手动重试沿用原 ID，服务端幂等因此只会存在一个 Run。
    expect(requestIds.toSet(), hasLength(1));
    expect(attempts, requestIds.length);
  });
}
