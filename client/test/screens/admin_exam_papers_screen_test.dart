import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/exam_paper.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/exam_papers/admin_exam_papers_screen.dart';
import 'package:shenliyuan/services/exam_paper_service.dart';

class _FakeAdminExamPaperService extends ExamPaperService {
  _FakeAdminExamPaperService() : super(Dio());

  String lastKeyword = '';
  String lastContributor = '';
  String lastSort = '';
  int approveCalls = 0;

  @override
  Future<List<ExamPaper>> adminListAll({
    required String status,
    String keyword = '',
    String contributor = '',
    String sort = 'oldest',
    int pageSize = 50,
  }) async {
    lastKeyword = keyword;
    lastContributor = contributor;
    lastSort = sort;
    return status == 'pending' ? [_paper()] : [];
  }

  @override
  Future<ExamPaper> approve({
    required int id,
    required String courseName,
    required String academicYear,
    required String semester,
    required String examType,
    String reason = '',
  }) async {
    approveCalls++;
    return _paper(status: 'published');
  }
}

class _OutOfOrderAdminService extends ExamPaperService {
  _OutOfOrderAdminService() : super(Dio());

  final requests = <String, Completer<List<ExamPaper>>>{};

  @override
  Future<List<ExamPaper>> adminListAll({
    required String status,
    String keyword = '',
    String contributor = '',
    String sort = 'oldest',
    int pageSize = 50,
  }) {
    if (keyword.isEmpty) {
      return Future.value(status == 'pending' ? [_paper()] : []);
    }
    return (requests['$status:$keyword'] ??= Completer<List<ExamPaper>>())
        .future;
  }
}

class _DelayedPublishedAdminService extends ExamPaperService {
  _DelayedPublishedAdminService() : super(Dio());

  final firstPublished = Completer<List<ExamPaper>>();
  int publishedCalls = 0;

  @override
  Future<List<ExamPaper>> adminListAll({
    required String status,
    String keyword = '',
    String contributor = '',
    String sort = 'oldest',
    int pageSize = 50,
  }) {
    if (status == 'pending') return Future.value([_paper()]);
    publishedCalls++;
    if (publishedCalls == 1) return firstPublished.future;
    return Future.value([_paper(status: 'published', courseName: '已发布结果')]);
  }
}

void main() {
  testWidgets('审核页支持服务端检索排序与二次确认快捷通过', (tester) async {
    final service = _FakeAdminExamPaperService();
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider(loadOnStart: false),
        child: MaterialApp(
          home: AdminExamPapersScreen(service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('搜索课程'), findsOneWidget);
    expect(find.text('搜索投稿人'), findsOneWidget);
    expect(find.text('最早提交'), findsOneWidget);
    expect(find.text('预览'), findsOneWidget);
    expect(find.text('审核'), findsOneWidget);
    expect(find.text('通过'), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('admin-paper-keyword')), '高等');
    await tester.enterText(
        find.byKey(const ValueKey('admin-paper-contributor')), '张同学');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();

    expect(service.lastKeyword, '高等');
    expect(service.lastContributor, '张同学');

    await tester.tap(find.text('通过'));
    await tester.pumpAndSettle();
    expect(find.text('确认通过该试卷？'), findsOneWidget);
    await tester.tap(find.text('确认通过'));
    await tester.pumpAndSettle();

    expect(service.approveCalls, 1);
  });

  testWidgets('管理员快速修改筛选时旧响应不会覆盖新结果', (tester) async {
    final service = _OutOfOrderAdminService();
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider(loadOnStart: false),
        child: MaterialApp(home: AdminExamPapersScreen(service: service)),
      ),
    );
    await tester.pumpAndSettle();

    final search = find.byKey(const ValueKey('admin-paper-keyword'));
    await tester.enterText(search, '旧');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.enterText(search, '新');
    await tester.pump(const Duration(milliseconds: 450));

    service.requests['pending:新']!.complete([_paper(courseName: '新结果')]);
    service.requests['published:新']!.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('新结果'), findsOneWidget);

    service.requests['pending:旧']!.complete([_paper(courseName: '旧结果')]);
    service.requests['published:旧']!.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('新结果'), findsOneWidget);
    expect(find.text('旧结果'), findsNothing);
  });

  testWidgets('任一 Tab 下拉刷新都会重新加载两组列表', (tester) async {
    final service = _DelayedPublishedAdminService();
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider(loadOnStart: false),
        child: MaterialApp(home: AdminExamPapersScreen(service: service)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    final refreshIndicator = tester.widget<RefreshIndicator>(
      find.byType(RefreshIndicator).first,
    );
    await refreshIndicator.onRefresh();
    await tester.pump();

    expect(service.publishedCalls, 2);
  });
}

ExamPaper _paper({String status = 'pending', String courseName = '高等数学'}) {
  return ExamPaper.fromJson({
    'id': 1,
    'status': status,
    'source': 'user',
    'course_name': courseName,
    'academic_year': '2025-2026',
    'semester': 'first',
    'exam_type': 'final',
    'title': '$courseName · 2025-2026 · 第一学期 · 期末',
    'file_size': 2048,
    'download_count': 0,
    'created_at': '2026-07-10T10:00:00Z',
    'contributor': {'id': 2, 'avatar': '', 'nickname': '张同学', 'level': 4},
  });
}
