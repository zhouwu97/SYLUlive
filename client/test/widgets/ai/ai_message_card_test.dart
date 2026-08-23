import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/ai_chat_message.dart';
import 'package:shenliyuan/models/ai_personal_data_evidence.dart';
import 'package:shenliyuan/widgets/ai/ai_message_card.dart';
import 'package:shenliyuan/theme/app_colors.dart';

void main() {
  final message = AiChatMessage(
    id: 'answer-1',
    requestId: 'run-1',
    role: AiMessageRole.assistant,
    content: '这是一个回答。',
    status: AiMessageStatus.completed,
    createdAt: DateTime.utc(2026, 8, 11),
  );

  testWidgets('AI 回答使用无外层气泡的 Agent 正文结构', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(body: AiMessageCard(message: message)),
      ),
    );

    final bubble = tester.widget<Container>(
      find.byKey(const ValueKey('ai-message-card-answer-1')),
    );
    expect(bubble.decoration, isNull);
    expect(find.text('校园 Agent'), findsOneWidget);
  });

  testWidgets('AI 回答在暗色主题下仍保持无外层气泡', (tester) async {
    final theme = ThemeData.dark(useMaterial3: true);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(body: AiMessageCard(message: message)),
      ),
    );

    final bubble = tester.widget<Container>(
      find.byKey(const ValueKey('ai-message-card-answer-1')),
    );
    expect(bubble.decoration, isNull);
    expect(find.text('校园 Agent'), findsOneWidget);
  });

  testWidgets('个人学业来源可展开核对成绩和学分输入', (tester) async {
    final academicMessage = AiChatMessage(
      id: 'answer-academic',
      requestId: 'run-academic',
      role: AiMessageRole.assistant,
      content: '你当前有两门课程需要优先处理。',
      status: AiMessageStatus.completed,
      createdAt: DateTime.utc(2026, 8, 12),
      personalDataEvidence: const [
        AiPersonalDataEvidence(
          source: 'hy3_mcp',
          dataset: 'academic_analysis',
          analysisInput: {
            'courses': [
              {
                'course_name': '信号与系统',
                'grade': 58,
                'credits': 3,
                'is_required': true,
                'passed': false,
              },
            ],
            'earned_credits': 25.5,
            'required_credits': 25.5,
            'erke_earned': 0,
            'erke_required': 0,
          },
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AiMessageCard(message: academicMessage)),
      ),
    );

    expect(find.text('个人数据来源'), findsOneWidget);
    await tester.tap(find.text('个人数据来源'));
    await tester.pumpAndSettle();
    expect(find.text('学业分析：学业数据来源'), findsOneWidget);
    expect(find.text('学分 25.5 / 25.5 · 二课 0 / 0'), findsOneWidget);
    expect(find.text('信号与系统'), findsOneWidget);
    expect(find.text('成绩 58 · 3 学分 · 必修 · 未通过'), findsOneWidget);
  });
}
