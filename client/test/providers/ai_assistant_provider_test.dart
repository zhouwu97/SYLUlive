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
}
