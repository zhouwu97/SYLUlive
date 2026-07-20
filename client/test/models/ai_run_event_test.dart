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
}
