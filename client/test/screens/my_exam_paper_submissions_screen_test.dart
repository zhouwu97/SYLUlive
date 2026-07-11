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
  _StatusExamPaperService({
    this.deleteError,
    this.expRevoked = false,
    this.deleteCompleter,
  }) : super(Dio());

  final requestedStatuses = <String>[];
  final deletedIds = <int>[];
  final removedIds = <int>{};
  final ExamPaperApiException? deleteError;
  final bool expRevoked;
  final Completer<ExamPaperDeleteResult>? deleteCompleter;

  @override
  Future<ExamPaperPage> mySubmissions({
    String status = '',
    int page = 1,
    int pageSize = 20,
  }) async {
    requestedStatuses.add(status);
    final allItems = [
      _paper(1, status: 'pending'),
      _paper(2, status: 'published', rewardRevocable: true),
      _paper(
        3,
        status: 'unpublished',
        unpublishReason: '文件清晰度不足',
      ),
    ].where((paper) => !removedIds.contains(paper.id)).toList();
    final items = switch (status) {
      'pending' => allItems.where((paper) => paper.isPending).toList(),
      'published' => allItems.where((paper) => paper.isPublished).toList(),
      'unpublished' => [
          ...allItems.where((paper) => paper.isUnpublished),
        ],
      _ => allItems,
    };
    return ExamPaperPage(
      items: items,
      page: 1,
      pageSize: 20,
      total: items.length,
      statusCounts: {
        'all': allItems.length,
        'pending': allItems.where((paper) => paper.isPending).length,
        'published': allItems.where((paper) => paper.isPublished).length,
        'unpublished': allItems.where((paper) => paper.isUnpublished).length,
      },
    );
  }

  @override
  Future<ExamPaperDeleteResult> deleteSubmission(int id) async {
    deletedIds.add(id);
    if (deleteError case final error?) throw error;
    final result = deleteCompleter == null
        ? ExamPaperDeleteResult(
            message: '投稿已删除',
            expRevoked: expRevoked,
          )
        : await deleteCompleter!.future;
    removedIds.add(id);
    return result;
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

  testWidgets('已发布和已下架投稿显示删除，待审核投稿仅显示撤回', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = _StatusExamPaperService();
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider(loadOnStart: false),
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: MyExamPaperSubmissionsScreen(service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('已通过 1'));
    await tester.tap(find.text('已通过 1'));
    await tester.pumpAndSettle();
    expect(find.text('删除'), findsOneWidget);
    expect(find.text('撤回'), findsNothing);

    await tester.ensureVisible(find.text('已下架 1'));
    await tester.tap(find.text('已下架 1'));
    await tester.pumpAndSettle();
    expect(find.text('重新投稿'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(find.text('撤回'), findsNothing);

    await tester.ensureVisible(find.text('待审核 1'));
    await tester.tap(find.text('待审核 1'));
    await tester.pumpAndSettle();
    expect(find.text('撤回'), findsOneWidget);
    expect(find.text('删除'), findsNothing);
  });

  testWidgets('已发布和已下架投稿的删除按钮使用危险色', (tester) async {
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

    await tester.tap(find.text('已通过 1'));
    await tester.pumpAndSettle();
    _expectDeleteButtonUsesErrorColor(tester);

    await tester.tap(find.text('已下架 1'));
    await tester.pumpAndSettle();
    _expectDeleteButtonUsesErrorColor(tester);
  });

  testWidgets('永久删除确认按奖励状态提示扣回经验且取消不发起请求', (tester) async {
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

    await tester.tap(find.text('已通过 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('永久删除投稿'), findsOneWidget);
    expect(find.textContaining('此操作不可恢复'), findsOneWidget);
    expect(find.textContaining('扣回'), findsOneWidget);
    expect(find.textContaining('10 经验'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.deletedIds, isEmpty);

    await tester.tap(find.text('已下架 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('永久删除投稿'), findsOneWidget);
    expect(find.textContaining('此操作不可恢复'), findsOneWidget);
    expect(find.textContaining('扣回'), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.deletedIds, isEmpty);
  });

  testWidgets('确认删除已下架投稿后刷新当前状态列表和计数', (tester) async {
    final service = _StatusExamPaperService(expRevoked: true);
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider(loadOnStart: false),
        child: MaterialApp(
          home: MyExamPaperSubmissionsScreen(service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('已下架 1'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('永久删除'));
    await tester.pumpAndSettle();

    expect(service.deletedIds, [3]);
    expect(service.requestedStatuses.last, 'unpublished');
    expect(find.text('已下架 0'), findsOneWidget);
    expect(find.text('测试课程3'), findsNothing);
    expect(find.textContaining('已扣回 10 经验'), findsOneWidget);
  });

  testWidgets('删除请求进行中时重复点击不会重复调用服务', (tester) async {
    final deleteCompleter = Completer<ExamPaperDeleteResult>();
    final service = _StatusExamPaperService(
      deleteCompleter: deleteCompleter,
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider(loadOnStart: false),
        child: MaterialApp(
          home: MyExamPaperSubmissionsScreen(service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('已下架 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('永久删除'));
    await tester.pumpAndSettle();
    expect(service.deletedIds, [3]);
    final deleteButton = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '删除'),
    );
    expect(deleteButton.onPressed, isNull);

    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pump();
    expect(service.deletedIds, [3]);
    expect(find.text('永久删除投稿'), findsNothing);

    deleteCompleter.complete(
      const ExamPaperDeleteResult(message: '投稿已删除', expRevoked: false),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('删除未扣回奖励时成功消息不展示扣回经验', (tester) async {
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
    await tester.tap(find.text('已下架 1'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('永久删除'));
    await tester.pumpAndSettle();

    expect(find.text('投稿已永久删除'), findsOneWidget);
    expect(find.textContaining('已扣回 10 经验'), findsNothing);
  });

  testWidgets('永久删除失败时保留投稿卡片并展示服务端错误', (tester) async {
    final service = _StatusExamPaperService(
      deleteError: const ExamPaperApiException(
        message: '该投稿当前无法删除',
        code: 'delete_not_allowed',
      ),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider(loadOnStart: false),
        child: MaterialApp(
          home: MyExamPaperSubmissionsScreen(service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('已下架 1'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('永久删除'));
    await tester.pumpAndSettle();

    expect(service.deletedIds, [3]);
    expect(find.text('测试课程3'), findsOneWidget);
    expect(find.text('该投稿当前无法删除'), findsOneWidget);
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

void _expectDeleteButtonUsesErrorColor(WidgetTester tester) {
  final finder = find.widgetWithText(TextButton, '删除');
  final button = tester.widget<TextButton>(finder);
  final context = tester.element(finder);
  expect(
    button.style?.foregroundColor?.resolve({}),
    Theme.of(context).colorScheme.error,
  );
}

ExamPaper _paper(
  int id, {
  String status = 'pending',
  String unpublishReason = '',
  bool rewardRevocable = false,
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
    'reward_revocable': rewardRevocable,
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
