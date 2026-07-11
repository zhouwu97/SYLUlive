import 'dart:async';

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
    String status = '',
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

class _StatusExamPaperService extends ExamPaperService {
  _StatusExamPaperService() : super(Dio());

  final requestedStatuses = <String>[];

  @override
  Future<ExamPaperPage> mySubmissions({
    String status = '',
    int page = 1,
    int pageSize = 20,
  }) async {
    requestedStatuses.add(status);
    final items = switch (status) {
      'pending' => [_paper(1, status: 'pending')],
      'published' => [_paper(2, status: 'published')],
      'unpublished' => [
          _paper(
            3,
            status: 'unpublished',
            unpublishReason: '文件清晰度不足',
          ),
        ],
      _ => [
          _paper(1, status: 'pending'),
          _paper(2, status: 'published'),
          _paper(
            3,
            status: 'unpublished',
            unpublishReason: '文件清晰度不足',
          ),
        ],
    };
    return ExamPaperPage(
      items: items,
      page: 1,
      pageSize: 20,
      total: items.length,
      statusCounts: const {
        'all': 3,
        'pending': 1,
        'published': 1,
        'unpublished': 1,
      },
    );
  }
}

class _OutOfOrderSubmissionService extends ExamPaperService {
  _OutOfOrderSubmissionService() : super(Dio());

  final oldRequest = Completer<ExamPaperPage>();
  final newRequest = Completer<ExamPaperPage>();
  final requestedStatuses = <String>[];

  @override
  Future<ExamPaperPage> mySubmissions({
    String status = '',
    int page = 1,
    int pageSize = 20,
  }) {
    requestedStatuses.add(status);
    if (status == 'pending') return oldRequest.future;
    if (status == 'unpublished') return newRequest.future;
    return Future.value(
      ExamPaperPage(
        items: [_paper(1, status: 'pending')],
        page: 1,
        pageSize: 20,
        total: 1,
        statusCounts: const {'all': 2, 'pending': 1, 'unpublished': 1},
      ),
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

  testWidgets('状态分段使用服务端计数并展示对应处理信息', (tester) async {
    final service = _StatusExamPaperService();
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider(loadOnStart: false),
        child: MaterialApp(
          home: MyExamPaperSubmissionsScreen(service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('全部 3'), findsOneWidget);
    expect(find.text('待审核 1'), findsOneWidget);
    expect(find.text('已通过 1'), findsOneWidget);
    expect(find.text('已下架 1'), findsOneWidget);
    expect(find.text('管理员审核中'), findsOneWidget);
    expect(find.text('已收录至试卷库'), findsOneWidget);

    await tester.tap(find.text('已下架 1'));
    await tester.pumpAndSettle();

    expect(service.requestedStatuses.last, 'unpublished');
    expect(find.text('原因：文件清晰度不足'), findsOneWidget);
    expect(find.text('重新投稿'), findsOneWidget);
  });

  testWidgets('快速切换投稿状态时旧响应不会覆盖新列表', (tester) async {
    final service = _OutOfOrderSubmissionService();
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider(loadOnStart: false),
        child: MaterialApp(
          home: MyExamPaperSubmissionsScreen(service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('待审核 1'));
    await tester.pump();
    await tester.tap(find.text('已下架 1'));
    await tester.pump();
    expect(service.requestedStatuses,
        containsAllInOrder(['all', 'pending', 'unpublished']));

    service.newRequest.complete(
      ExamPaperPage(
        items: [_paper(2, status: 'unpublished', unpublishReason: '新结果')],
        page: 1,
        pageSize: 20,
        total: 1,
        statusCounts: const {'all': 2, 'pending': 1, 'unpublished': 1},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('原因：新结果'), findsOneWidget);

    service.oldRequest.complete(
      ExamPaperPage(
        items: [_paper(3, status: 'pending')],
        page: 1,
        pageSize: 20,
        total: 1,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('原因：新结果'), findsOneWidget);
    expect(find.text('测试课程3'), findsNothing);
  });
}

ExamPaper _paper(
  int id, {
  String status = 'pending',
  String unpublishReason = '',
}) {
  return ExamPaper.fromJson({
    'id': id,
    'status': status,
    'source': 'user',
    'course_name': '测试课程$id',
    'academic_year': '2025-2026',
    'semester': 'first',
    'exam_type': 'final',
    'title': '测试课程$id · 2025-2026 · 第一学期 · 期末',
    'file_size': 1024,
    'download_count': 0,
    'unpublish_reason': unpublishReason,
    'created_at': '2026-07-10T10:00:00Z',
    'contributor': {
      'id': 1,
      'avatar': '',
      'nickname': '测试用户',
      'level': 1,
    },
  });
}
