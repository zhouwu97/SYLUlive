import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/ai_chat_message.dart';
import 'package:shenliyuan/models/ai_source.dart';
import 'package:shenliyuan/widgets/ai/ai_message_card.dart';

void main() {
  testWidgets('政策消息不展示裸 chunk ID，并展示聚合引用位置', (tester) async {
    final message = AiChatMessage(
      id: 'message-1',
      requestId: 'request-1',
      role: AiMessageRole.assistant,
      content: '请按规定办理。[chunk:18]',
      status: AiMessageStatus.completed,
      createdAt: DateTime.utc(2026, 7, 28),
      sources: const [
        AiSource(
          type: AiSourceType.policy,
          chunkId: 18,
          documentId: 3,
          title: '学生手册',
          publisher: '学生处',
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

    await tester.tap(find.text('学生手册'));
    await tester.pumpAndSettle();
    expect(find.textContaining('第十条 · 第十一条'), findsOneWidget);
  });
}
