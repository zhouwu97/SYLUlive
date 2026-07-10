import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/competition_batch_action_payload.dart';

void main() {
  group('buildCompetitionCalendarBatchActionPayload', () {
    test('计划状态操作映射为 set_plan_status', () {
      for (final status in [
        'preparing',
        'registered',
        'submitted',
        'finished'
      ]) {
        expect(
          buildCompetitionCalendarBatchActionPayload(
            ids: const [1, 2],
            action: status,
          ),
          {
            'ids': [1, 2],
            'action': 'set_plan_status',
            'plan_status': status,
          },
        );
      }
    });

    test('恢复、归档和删除映射为后端动作', () {
      expect(
        buildCompetitionCalendarBatchActionPayload(
          ids: const [1, 1, 2],
          action: 'watching',
        ),
        {
          'ids': [1, 2],
          'action': 'restore',
        },
      );
      expect(
        buildCompetitionCalendarBatchActionPayload(
          ids: const [1],
          action: 'archived',
        ),
        {
          'ids': [1],
          'action': 'archive',
        },
      );
      expect(
        buildCompetitionCalendarBatchActionPayload(
          ids: const [1],
          action: 'delete',
        ),
        {
          'ids': [1],
          'action': 'delete',
        },
      );
    });

    test('拒绝未知操作', () {
      expect(
        () => buildCompetitionCalendarBatchActionPayload(
          ids: const [1],
          action: 'unknown',
        ),
        throwsArgumentError,
      );
    });
  });
}
