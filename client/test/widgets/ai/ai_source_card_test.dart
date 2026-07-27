import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/ai_chat_message.dart';
import 'package:shenliyuan/models/ai_source.dart';
import 'package:shenliyuan/widgets/ai/ai_message_card.dart';

void main() {
  testWidgets('政策消息不展示裸 chunk ID，并展示聚合引用位置', (tester) async {
    const title = '沈阳理工大学本科课程考核与成绩管理办法（完整正式版本）';
    final message = AiChatMessage(
      id: 'message-1',
      requestId: 'request-1',
      role: AiMessageRole.assistant,
      content: '请按规定办理。[chunk:18]',
      status: AiMessageStatus.completed,
      createdAt: DateTime.utc(2026, 7, 28),
      sources: [
        AiSource(
          type: AiSourceType.policy,
          chunkId: 18,
          documentId: 3,
          title: title,
          publisher: '学生处',
          status: 'published',
          effectiveFrom: DateTime.utc(2025, 9, 1),
          effectiveTo: DateTime.utc(2027, 8, 31),
          citationNumbers: [1, 2],
          locators: ['第十条', '第十一条'],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: AiMessageCard(message: message))),
    );

    expect(find.textContaining('chunk:18'), findsNothing);
    expect(find.textContaining('来源'), findsOneWidget);
    expect(find.textContaining('[1][2]'), findsOneWidget);
    expect(tester.widget<Text>(find.text(title)).maxLines, 2);

    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text(title)).maxLines, isNull);
    expect(find.text('发布部门'), findsOneWidget);
    expect(find.text('学生处'), findsOneWidget);
    expect(find.text('文档状态'), findsOneWidget);
    expect(find.text('已发布'), findsOneWidget);
    expect(find.text('生效时间'), findsOneWidget);
    expect(find.text('2025-09-01 至 2027-08-31'), findsOneWidget);
    expect(find.text('条款位置'), findsOneWidget);
    expect(find.textContaining('第十条 · 第十一条'), findsOneWidget);
  });
}
