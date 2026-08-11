import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/ai_chat_message.dart';
import 'package:shenliyuan/widgets/ai/ai_message_card.dart';
import 'package:shenliyuan/widgets/campus/campus_theme.dart';

void main() {
  final message = AiChatMessage(
    id: 'answer-1',
    requestId: 'run-1',
    role: AiMessageRole.assistant,
    content: '这是一个回答。',
    status: AiMessageStatus.completed,
    createdAt: DateTime.utc(2026, 8, 11),
  );

  testWidgets('AI 回答使用校园青绿色 surface，而不是 Material 紫灰色', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(body: AiMessageCard(message: message)),
      ),
    );

    final bubble = tester.widget<Container>(
      find.byKey(const ValueKey('ai-message-card-answer-1')),
    );
    final decoration = bubble.decoration! as BoxDecoration;
    expect(decoration.color, CampusTheme.primaryLight);
    expect((decoration.border! as Border).top.color, CampusTheme.border);
  });

  testWidgets('AI 回答在暗色主题下沿用页面品牌容器色', (tester) async {
    final theme = CampusTheme.withBrandAccent(
      ThemeData.dark(useMaterial3: true),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(body: AiMessageCard(message: message)),
      ),
    );

    final bubble = tester.widget<Container>(
      find.byKey(const ValueKey('ai-message-card-answer-1')),
    );
    expect(
      (bubble.decoration! as BoxDecoration).color,
      theme.colorScheme.primaryContainer,
    );
  });
}
