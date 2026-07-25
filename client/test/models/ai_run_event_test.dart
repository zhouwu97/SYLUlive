import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/ai_run_event.dart';

void main() {
  test('解析后端 SSE 事件及 payload', () {
    final event = AiRunEvent.parseSse(
      '{"run_id":"run-1","seq":7,"type":"sources.ready","timestamp":"2026-07-19T10:00:00Z","payload":{"sources":[{"type":"policy","title":"学生手册","publisher":"教务处"}]}}',
      eventName: 'sources.ready',
    );

    expect(event.runId, 'run-1');
    expect(event.seq, 7);
    expect(event.type, AiRunEventType.sources);
    expect(event.sources.single.title, '学生手册');
  });

  test('终态和错误码映射正确', () {
    final event = AiRunEvent.parseSse(
      '{"run_id":"run-1","seq":8,"type":"run.failed","payload":{"code":"rag_unavailable","retryable":true}}',
    );
    expect(event.type, AiRunEventType.failed);
    expect(event.errorCode, 'rag_unavailable');
    expect(event.retryable, isTrue);
  });

  test('个人数据证据事件只解析来源元数据', () {
    final event = AiRunEvent.parseSse(
      '{"run_id":"run-1","seq":9,"type":"personal_data.evidence",'
      '"payload":{"call_id":"call-1","evidence":[{'
      '"source":"device_encrypted_cache","dataset":"schedule",'
      '"fetched_at":"2026-07-25T09:20:00Z","is_stale":true}]}}',
    );

    expect(event.type, AiRunEventType.personalDataEvidence);
    expect(event.personalDataEvidence, hasLength(1));
    expect(event.personalDataEvidence.single.sourceLabel, '手机本地加密缓存');
    expect(event.personalDataEvidence.single.datasetLabel, '课表');
    expect(event.personalDataEvidence.single.isStale, isTrue);
  });
}
