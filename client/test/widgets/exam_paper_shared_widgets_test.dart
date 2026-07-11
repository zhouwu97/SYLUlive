import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/exam_papers/exam_paper_empty_state.dart';
import 'package:shenliyuan/widgets/exam_papers/exam_paper_list_skeleton.dart';
import 'package:shenliyuan/widgets/exam_papers/exam_paper_status_badge.dart';

void main() {
  testWidgets('空状态展示说明并触发主操作', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExamPaperEmptyState(
            icon: Icons.library_books_outlined,
            title: '暂时没有试卷',
            message: '可以投稿第一份试卷。',
            primaryActionLabel: '去投稿',
            onPrimaryAction: () => tapped = true,
          ),
        ),
      ),
    );

    expect(find.text('暂时没有试卷'), findsOneWidget);
    expect(find.text('可以投稿第一份试卷。'), findsOneWidget);
    await tester.tap(find.text('去投稿'));
    expect(tapped, isTrue);
  });

  testWidgets('骨架屏稳定展示三项', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ExamPaperListSkeleton()),
      ),
    );

    expect(find.byKey(const ValueKey('exam-paper-skeleton-item')),
        findsNWidgets(3));
  });

  testWidgets('状态徽标使用统一中文文案', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Wrap(
            children: [
              ExamPaperStatusBadge(status: 'pending'),
              ExamPaperStatusBadge(status: 'published'),
              ExamPaperStatusBadge(status: 'unpublished'),
            ],
          ),
        ),
      ),
    );

    expect(find.text('待审核'), findsOneWidget);
    expect(find.text('已通过'), findsOneWidget);
    expect(find.text('已下架'), findsOneWidget);
  });
}
