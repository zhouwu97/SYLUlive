import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/exam_paper_access_guide.dart';

void main() {
  testWidgets('未登录与未认证引导使用不同文案和操作', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExamPaperAccessGuide(
            type: ExamPaperAccessGuideType.login,
            onAction: () {},
          ),
        ),
      ),
    );
    expect(find.text('登录后使用试卷库'), findsOneWidget);
    expect(find.text('去登录'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExamPaperAccessGuide(
            type: ExamPaperAccessGuideType.eduVerification,
            onAction: () {},
          ),
        ),
      ),
    );
    expect(find.text('完成教务认证后使用'), findsOneWidget);
    expect(find.text('去认证'), findsOneWidget);
  });
}
