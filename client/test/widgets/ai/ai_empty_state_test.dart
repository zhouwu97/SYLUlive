import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/ai_quick_prompt.dart';
import 'package:shenliyuan/widgets/ai/ai_empty_state.dart';

void main() {
  testWidgets('校园 Agent 空态展示 HTML 四项常用能力', (tester) async {
    String? selectedPrompt;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiPublicEmptyState(
            chatEnabled: true,
            quickPrompts: const <AiQuickPrompt>[
              AiQuickPrompt(
                category: '学业考试',
                question: '补考成绩怎么算',
                feature: AiQuickPromptFeature.policy,
              ),
              AiQuickPrompt(
                category: '教学管理',
                question: '重修有什么规定',
                feature: AiQuickPromptFeature.policy,
              ),
              AiQuickPrompt(
                category: '奖助评优',
                question: '奖学金怎么评',
                feature: AiQuickPromptFeature.policy,
              ),
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

    expect(find.text('今天想让 Agent 帮你做什么？'), findsOneWidget);
    expect(find.text('常用能力'), findsOneWidget);
    expect(find.text('本周空闲'), findsOneWidget);
    expect(find.text('学业风险'), findsOneWidget);
    expect(find.text('近期竞赛'), findsOneWidget);
    expect(find.text('学校政策'), findsOneWidget);
    expect(find.text('猜你想问'), findsNothing);

    await tester.tap(find.text('学业风险'));
    expect(selectedPrompt, '分析我的学业情况，找出主要风险并给出改进建议');
    expect(tester.takeException(), isNull);
  });
}
