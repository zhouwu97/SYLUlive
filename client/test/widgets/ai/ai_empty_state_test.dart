import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/ai/ai_empty_state.dart';

void main() {
  testWidgets('AI 业务入口合并到常用问题且保持四项紧凑布局', (tester) async {
    String? selectedPrompt;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiPublicEmptyState(
            chatEnabled: true,
            quickPrompts: const <String>[
              '补考成绩怎么算',
              '重修有什么规定',
              '奖学金怎么评',
            ],
            suggestedPrompts: const <AiSuggestedPrompt>[
              AiSuggestedPrompt(
                title: '学业分析',
                subtitle: '识别风险并整理改进建议',
                prompt: '分析我的学业情况，找出主要风险并给出改进建议',
              ),
              AiSuggestedPrompt(
                title: '本周计划',
                subtitle: '结合课表与目标安排一周',
                prompt: '结合我的课表和目标，帮我制定本周学习计划',
              ),
            ],
            onPromptSelected: (prompt) => selectedPrompt = prompt,
          ),
        ),
      ),
    );

    expect(find.text('常用问题'), findsOneWidget);
    expect(find.text('学业分析'), findsOneWidget);
    expect(find.text('本周计划'), findsOneWidget);
    expect(find.text('学业考试'), findsOneWidget);
    expect(find.text('教学管理'), findsOneWidget);
    expect(find.text('奖助评优'), findsNothing);

    await tester.tap(find.text('学业分析'));
    expect(selectedPrompt, '分析我的学业情况，找出主要风险并给出改进建议');
    expect(tester.takeException(), isNull);
  });
}
