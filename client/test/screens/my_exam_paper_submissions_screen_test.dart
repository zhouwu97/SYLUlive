import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/exam_paper.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/exam_papers/my_exam_paper_submissions_screen.dart';
import 'package:shenliyuan/services/exam_paper_service.dart';

class _LoadMoreFailingExamPaperService extends ExamPaperService {
  _LoadMoreFailingExamPaperService() : super(Dio());

  @override
  Future<ExamPaperPage> mySubmissions({
    int page = 1,
    int pageSize = 20,
  }) async {
    if (page == 1) {
      return ExamPaperPage(
        items: List.generate(12, (index) => _paper(index + 1)),
        page: 1,
        pageSize: 12,
        total: 13,
      );
    }
    throw const ExamPaperApiException(
      message: '下一页加载失败',
      code: 'network_error',
    );
  }
}

void main() {
  testWidgets('我的投稿加载更多失败时展示错误提示', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider(loadOnStart: false),
        child: MaterialApp(
          home: MyExamPaperSubmissionsScreen(
            service: _LoadMoreFailingExamPaperService(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -2400));
    await tester.pumpAndSettle();

    expect(find.text('下一页加载失败'), findsOneWidget);
  });
}

ExamPaper _paper(int id) {
  return ExamPaper.fromJson({
    'id': id,
    'status': 'pending',
    'source': 'user',
    'course_name': '测试课程$id',
    'academic_year': '2025-2026',
    'semester': 'first',
    'exam_type': 'final',
    'title': '测试课程$id · 2025-2026 · 第一学期 · 期末',
    'file_size': 1024,
    'download_count': 0,
    'created_at': '2026-07-10T10:00:00Z',
    'contributor': {
      'id': 1,
      'avatar': '',
      'nickname': '测试用户',
      'level': 1,
    },
  });
}
