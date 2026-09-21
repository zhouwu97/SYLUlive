import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/feedback_ticket.dart';
import 'package:shenliyuan/services/device_diagnostics_service.dart';

void main() {
  group('FeedbackTicket Model Tests', () {
    test('正确解析工单状态与类型展示', () {
      final ticketJson = {
        'id': 1,
        'ticket_no': 'SY2609140018',
        'user_id': 10,
        'type': 'bug',
        'title': '课表时间不同步',
        'description': '重新同步后无变化',
        'status': 'testing',
        'status_note': '内测版 v2.8.3',
        'admin_viewed': true,
        'created_at': '2026-09-14T09:20:00Z',
        'updated_at': '2026-09-14T09:42:00Z',
      };

      final ticket = FeedbackTicket.fromJson(ticketJson);
      expect(ticket.id, 1);
      expect(ticket.ticketNo, 'SY2609140018');
      expect(ticket.typeLabel, '问题反馈');
      expect(ticket.statusDisplayName, '测试中');
    });

    test('未查看状态正确展示复合标签', () {
      final pendingUnviewed = FeedbackTicket.fromJson({
        'id': 2,
        'ticket_no': 'SY2609140019',
        'user_id': 10,
        'type': 'suggestion',
        'title': '希望增加空教室查询',
        'description': '自习找教室方便',
        'status': 'pending',
        'admin_viewed': false,
        'created_at': '2026-09-14T09:20:00Z',
        'updated_at': '2026-09-14T09:20:00Z',
      });

      expect(pendingUnviewed.typeLabel, '功能建议');
      expect(pendingUnviewed.statusDisplayName, '待受理');

      final pendingViewed = FeedbackTicket.fromJson({
        'id': 3,
        'ticket_no': 'SY2609140020',
        'user_id': 10,
        'type': 'other',
        'title': '咨询问题',
        'description': '咨询',
        'status': 'waiting_user',
        'admin_viewed': true,
        'created_at': '2026-09-14T09:20:00Z',
        'updated_at': '2026-09-14T09:20:00Z',
      });

      expect(pendingViewed.typeLabel, '其他');
      expect(pendingViewed.statusDisplayName, '待你补充');
    });

    test('消息类型及内部备注可见性判断', () {
      final internalNote = FeedbackMessage.fromJson({
        'id': 101,
        'ticket_id': 1,
        'sender_type': 'admin',
        'sender_id': 99,
        'message_type': 'internal_note',
        'content': '待复现 ScheduleOverrideRepository',
        'visible_to_user': false,
        'created_at': '2026-09-14T09:30:00Z',
      });

      expect(internalNote.isInternalNote, isTrue);
      expect(internalNote.visibleToUser, isFalse);
      expect(internalNote.isAdmin, isTrue);

      final reqInfo = FeedbackMessage.fromJson({
        'id': 102,
        'ticket_id': 1,
        'sender_type': 'admin',
        'sender_id': 99,
        'message_type': 'request_info',
        'content': '请提供具体上课时间与课程名',
        'metadata_json': '{"requested_items":["screenshot","steps"]}',
        'visible_to_user': true,
        'created_at': '2026-09-14T09:35:00Z',
      });

      expect(reqInfo.isRequestInfo, isTrue);
      expect(reqInfo.visibleToUser, isTrue);
    });
  });

  group('DeviceDiagnosticsService Tests', () {
    test('安全诊断信息包含基本环境且排除凭据', () async {
      final info = await DeviceDiagnosticsService.collect(currentRoute: '课表模块');
      expect(info.appVersion, isNotEmpty);
      expect(info.currentRoute, '课表模块');
      expect(info.summaryText, contains('当前位置：课表模块'));

      final jsonStr = info.toJsonString();
      expect(jsonStr, contains('privacy_guarantee'));
      expect(jsonStr, isNot(contains('password')));
      expect(jsonStr, isNot(contains('token')));
      expect(jsonStr, isNot(contains('cookie')));
    });
  });

  group('Feedback UI Components Tests', () {
    testWidgets('工单状态 Badge 正确渲染', (tester) async {
      final ticket = FeedbackTicket(
        id: 1,
        ticketNo: 'SY2609140018',
        userId: 10,
        type: 'bug',
        title: '课表刷新无变化',
        description: '描述',
        status: 'waiting_user',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) {
              return Text(ticket.statusDisplayName);
            }),
          ),
        ),
      );

      expect(find.text('待你补充'), findsOneWidget);
    });
  });
}
