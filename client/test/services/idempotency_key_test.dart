import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/feedback_ticket.dart';
import 'package:shenliyuan/services/idempotency_key.dart';

void main() {
  group('resolveIdempotencyKey', () {
    test('指纹一致是原样重试，复用同一把键', () {
      const fingerprint = 'same-request';
      final key = resolveIdempotencyKey(fingerprint: fingerprint);
      expect(
        resolveIdempotencyKey(
          fingerprint: fingerprint,
          pendingFingerprint: fingerprint,
          pendingKey: key,
        ),
        key,
        reason: '响应丢失后的重试必须被服务端认成同一次提交',
      );
    });

    test('指纹变化是新的一次操作，换新键', () {
      const key = 'previous-key';
      expect(
        resolveIdempotencyKey(
          fingerprint: 'edited-request',
          pendingFingerprint: 'original-request',
          pendingKey: key,
        ),
        isNot(key),
        reason: '拿旧键发新请求体只会换来 idempotency_key_reused',
      );
    });

    test('没有待确认请求时生成新键', () {
      expect(resolveIdempotencyKey(fingerprint: 'any'), isNotEmpty);
    });
  });

  group('工单消息请求指纹', () {
    test('内容、附件、可见范围任一变化都算新的一条消息', () {
      final base = feedbackMessageFingerprint(
        content: '第一条',
        imageIds: const [1, 2],
        visibleToUser: true,
      );
      expect(
        feedbackMessageFingerprint(
            content: '改了措辞', imageIds: const [1, 2], visibleToUser: true),
        isNot(base),
      );
      expect(
        feedbackMessageFingerprint(
            content: '第一条', imageIds: const [1, 2, 3], visibleToUser: true),
        isNot(base),
        reason: '补了图片就是新的一条消息',
      );
      expect(
        feedbackMessageFingerprint(
            content: '第一条', imageIds: const [1, 2], visibleToUser: false),
        isNot(base),
        reason: '"用户可见"切成内部备注后不能再用上一条的幂等键',
      );
      expect(
        feedbackMessageFingerprint(
            content: '第一条', imageIds: const [1, 2], visibleToUser: true),
        base,
      );
    });

    test('图片顺序变化也算新的一条消息', () {
      expect(
        feedbackMessageFingerprint(
            content: 'x', imageIds: const [1, 2], visibleToUser: true),
        isNot(feedbackMessageFingerprint(
            content: 'x', imageIds: const [2, 1], visibleToUser: true)),
      );
    });
  });
}
