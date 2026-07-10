import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/exam_paper.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/widgets/exam_paper_card.dart';

void main() {
  testWidgets('试卷卡片展示标题、贡献者等级与下载量', (tester) async {
    final paper = ExamPaper.fromJson({
      'id': 1,
      'status': 'published',
      'source': 'user',
      'course_name': '高等数学',
      'academic_year': '2025-2026',
      'semester': 'first',
      'exam_type': 'final',
      'title': '高等数学 · 2025-2026 · 第一学期 · 期末',
      'file_size': 2048,
      'download_count': 18,
      'published_at': '2026-07-10T10:00:00Z',
      'created_at': '2026-07-09T10:00:00Z',
      'contributor': {'id': 2, 'avatar': '', 'nickname': '贡献者', 'level': 4},
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider(loadOnStart: false),
        child: MaterialApp(
          home: Scaffold(
            body: ExamPaperCard(paper: paper, onTap: () {}),
          ),
        ),
      ),
    );

    expect(find.text(paper.title), findsOneWidget);
    expect(find.textContaining('贡献者'), findsOneWidget);
    expect(find.textContaining('Lv.4'), findsOneWidget);
    expect(find.textContaining('18'), findsOneWidget);
    expect(find.text('已通过'), findsOneWidget);
  });
}
