import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/exam_paper.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/exam_papers/exam_paper_library_screen.dart';
import 'package:shenliyuan/services/exam_paper_service.dart';

class _FakeAuthProvider extends AuthProvider {
  _FakeAuthProvider(this.fakeUser) : super(Dio());

  final User fakeUser;
  final Dio fakeDio = Dio();

  @override
  User? get user => fakeUser;

  @override
  bool get isLoggedIn => true;

  @override
  bool get isInitialized => true;

  @override
  Dio get dio => fakeDio;

  @override
  Future<void> refreshUser() async {}
}

class _FakeExamPaperService extends ExamPaperService {
  _FakeExamPaperService() : super(Dio());

  @override
  Future<ExamPaperPage> list({
    String keyword = '',
    String academicYear = '',
    String semester = '',
    String examType = '',
    String sort = 'latest',
    int page = 1,
    int pageSize = 20,
  }) async {
    return ExamPaperPage(
        items: const [], page: page, pageSize: pageSize, total: 0);
  }
}

class _OutOfOrderExamPaperService extends ExamPaperService {
  _OutOfOrderExamPaperService() : super(Dio());

  final oldRequest = Completer<ExamPaperPage>();
  final newRequest = Completer<ExamPaperPage>();

  @override
  Future<ExamPaperPage> list({
    String keyword = '',
    String academicYear = '',
    String semester = '',
    String examType = '',
    String sort = 'latest',
    int page = 1,
    int pageSize = 20,
  }) {
    if (keyword == 'old') return oldRequest.future;
    if (keyword == 'new') return newRequest.future;
    return Future.value(
      const ExamPaperPage(items: [], page: 1, pageSize: 20, total: 0),
    );
  }
}

void main() {
  testWidgets('已认证用户看到搜索筛选、我的投稿和投稿入口', (tester) async {
    final user = User(
      id: 1,
      studentId: '20260001',
      nickname: '测试用户',
      eduBound: true,
      createdAt: DateTime(2026),
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeProvider>(
            create: (_) => ThemeProvider(loadOnStart: false),
          ),
          ChangeNotifierProvider<AuthProvider>(
            create: (_) => _FakeAuthProvider(user),
          ),
        ],
        child: MaterialApp(
          home: ExamPaperLibraryScreen(service: _FakeExamPaperService()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('试卷库'), findsOneWidget);
    expect(find.text('搜索课程名'), findsOneWidget);
    expect(find.byTooltip('我的投稿'), findsOneWidget);
    expect(find.text('投稿'), findsOneWidget);
    expect(find.text('暂无符合条件的试卷'), findsOneWidget);
  });

  testWidgets('搜索请求乱序返回时只展示最新关键词结果', (tester) async {
    final user = User(
      id: 1,
      studentId: '20260001',
      nickname: '测试用户',
      eduBound: true,
      createdAt: DateTime(2026),
    );
    final service = _OutOfOrderExamPaperService();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeProvider>(
            create: (_) => ThemeProvider(loadOnStart: false),
          ),
          ChangeNotifierProvider<AuthProvider>(
            create: (_) => _FakeAuthProvider(user),
          ),
        ],
        child: MaterialApp(
          home: ExamPaperLibraryScreen(service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final search = find.byType(TextField);
    await tester.enterText(search, 'old');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.enterText(search, 'new');
    await tester.pump(const Duration(milliseconds: 450));

    service.newRequest.complete(
      ExamPaperPage(
        items: [_paper(2, '最新结果')],
        page: 1,
        pageSize: 20,
        total: 1,
      ),
    );
    await tester.pump();
    expect(find.text('最新结果'), findsOneWidget);

    service.oldRequest.complete(
      ExamPaperPage(
        items: [_paper(1, '过期结果')],
        page: 1,
        pageSize: 20,
        total: 1,
      ),
    );
    await tester.pump();

    expect(find.text('最新结果'), findsOneWidget);
    expect(find.text('过期结果'), findsNothing);
  });
}

ExamPaper _paper(int id, String title) {
  return ExamPaper.fromJson({
    'id': id,
    'status': 'published',
    'source': 'user',
    'course_name': title,
    'academic_year': '2025-2026',
    'semester': 'first',
    'exam_type': 'final',
    'title': title,
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
