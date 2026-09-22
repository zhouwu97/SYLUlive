import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/idempotency_key.dart';

void main() {
  group('idempotencyOutcomeFor', () {
    test('结果未知或键已占用时必须换新键', () {
      // 服务端状态机的三个终态：键绑到别的请求体、中途崩溃、未决超时。
      for (final code in [
        'idempotency_key_reused',
        'idempotency_request_failed',
        'idempotency_request_expired',
      ]) {
        expect(idempotencyOutcomeFor(code), IdempotencyOutcome.exhausted,
            reason: '$code 之后继续沿用同一把键只会让用户卡住');
      }
    });

    test('同一请求仍在处理时保留原键', () {
      expect(idempotencyOutcomeFor('idempotency_request_in_progress'),
          IdempotencyOutcome.inProgress);
    });

    test('普通业务错误与幂等无关，保留原键', () {
      for (final code in [
        'poll_rate_limited',
        'poll_title_required',
        'poll_network_error',
        'feedback_rate_limited',
        '',
        null,
      ]) {
        expect(idempotencyOutcomeFor(code), IdempotencyOutcome.none,
            reason: '$code 是内容问题，原样重试应当仍算同一次提交');
      }
    });
  });

  group('idempotencyUserMessage', () {
    test('幂等冲突换成可执行提示，其余透传原文案', () {
      expect(idempotencyUserMessage('idempotency_key_reused', '服务端原文'),
          contains('再点一次提交'));
      expect(idempotencyUserMessage('idempotency_request_failed', '服务端原文'),
          contains('刷新确认'));
      expect(idempotencyUserMessage('poll_rate_limited', '操作过于频繁'),
          '操作过于频繁');
    });
  });
}
