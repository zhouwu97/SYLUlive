import 'package:flutter_test/flutter_test.dart';

import 'package:shenliyuan/models/user_calendar.dart';

void main() {
  test('保留服务端写后回读未确认状态', () {
    final draft = UserCalendarActionDraft.fromJson(<String, dynamic>{
      'id': 7,
      'action_type': 'calendar_event_create',
      'status': 'executed',
      'title': '训练',
      'description': '',
      'start_at': '2026-08-24T09:00:00Z',
      'end_at': '2026-08-24T10:00:00Z',
      'all_day': false,
      'location': '',
      'timezone': 'Asia/Shanghai',
      'expires_at': '2026-08-24T08:00:00Z',
      'postcondition_verified': false,
      'postcondition_error': 'postcondition_not_confirmed',
    });

    expect(draft.postconditionVerified, isFalse);
    expect(draft.postconditionError, 'postcondition_not_confirmed');
    expect(draft.toJson()['postcondition_verified'], isFalse);
  });
}
