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

  test('answer.rollback 解析为绝对文本事件', () {
    final event = AiRunEvent.parseSse(
      '{"run_id":"run-1","seq":10,"type":"answer.rollback","payload":{"text":""}}',
    );
    expect(event.type, AiRunEventType.rollback);
    expect(event.text, '');

    final nonEmpty = AiRunEvent.parseSse(
      '{"run_id":"run-1","seq":11,"type":"answer.rollback","payload":{"text":"已回滚到检查点"}}',
    );
    expect(nonEmpty.type, AiRunEventType.rollback);
    expect(nonEmpty.text, '已回滚到检查点');
  });

  test('按文档聚合来源并解析公开引用编号', () {
    final event = AiRunEvent.parseSse(
      '{"run_id":"run-1","seq":9,"type":"sources.ready","payload":{"sources":[{"document_id":3,"primary_chunk_id":18,"title":"学生手册","department":"学生处","status":"published","effective_from":"2025-09-01T00:00:00+08:00","effective_to":"2027-08-31T23:59:59+08:00","citation_numbers":[1,2],"locators":["第十条","第十一条"]}]}}',
    );

    final source = event.sources.single;
    expect(source.documentId, 3);
    expect(source.chunkId, 18);
    expect(source.publisher, '学生处');
    expect(source.statusLabel, '已发布');
    expect(source.effectiveLabel, '2025-09-01 至 2027-08-31');
    expect(source.citationLabel, '[1][2]');
    expect(source.locators, ['第十条', '第十一条']);
    expect(source.locatorLabel, '第十条 · 第十一条');
  });
}
