import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/exam_paper.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/exam_papers/admin_exam_papers_screen.dart';
import 'package:shenliyuan/screens/exam_papers/exam_paper_library_screen.dart';
import 'package:shenliyuan/screens/exam_papers/exam_paper_upload_screen.dart';
import 'package:shenliyuan/screens/exam_papers/my_exam_paper_submissions_screen.dart';
import 'package:shenliyuan/services/exam_paper_service.dart';

class _ResponsiveAuthProvider extends AuthProvider {
  _ResponsiveAuthProvider() : super(Dio());

  final _user = User(
    id: 1,
    studentId: '20260001',
    nickname: '测试用户',
    eduBound: true,
    createdAt: DateTime(2026),
  );

  @override
  User? get user => _user;

  @override
  bool get isLoggedIn => true;

  @override
  bool get isInitialized => true;
}

class _ResponsiveExamPaperService extends ExamPaperService {
  _ResponsiveExamPaperService() : super(Dio());

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
      items: [_paper()],
      page: 1,
      pageSize: 20,
      total: 1,
    );
  }

  @override
  Future<ExamPaperPage> mySubmissions({
    String status = '',
    int page = 1,
    int pageSize = 20,
  }) async {
    return ExamPaperPage(
      items: [_paper()],
      page: 1,
      pageSize: 20,
      total: 1,
      statusCounts: const {'all': 1, 'pending': 1},
    );
  }

  @override
  Future<List<ExamPaper>> adminListAll({
    required String status,
    String keyword = '',
    String contributor = '',
    String sort = 'oldest',
    int pageSize = 50,
  }) async {
    return status == 'pending' ? [_paper()] : [];
  }
}

void main() {
  testWidgets('四个试卷页面在 320px 暗色视口无布局异常', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = _ResponsiveExamPaperService();

    await tester.pumpWidget(_app(
      child: ExamPaperLibraryScreen(service: service),
      withAuth: true,
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(_app(
      child: ExamPaperUploadScreen(service: service, isAdmin: false),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(_app(
      child: MyExamPaperSubmissionsScreen(service: service),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(_app(
      child: AdminExamPapersScreen(service: service),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

Widget _app({required Widget child, bool withAuth = false}) {
  final providers = <ChangeNotifierProvider>[
    ChangeNotifierProvider<ThemeProvider>(
      create: (_) => ThemeProvider(loadOnStart: false),
    ),
    if (withAuth)
      ChangeNotifierProvider<AuthProvider>(
        create: (_) => _ResponsiveAuthProvider(),
      ),
  ];
  return MultiProvider(
    providers: providers,
    child: MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: child,
    ),
  );
}

ExamPaper _paper() {
  return ExamPaper.fromJson({
    'id': 1,
    'status': 'pending',
    'source': 'user',
    'course_name': '高等数学',
    'academic_year': '2025-2026',
    'semester': 'first',
    'exam_type': 'final',
    'title': '高等数学 · 2025-2026 · 第一学期 · 期末',
    'file_size': 2048,
    'download_count': 0,
    'created_at': '2026-07-10T10:00:00Z',
    'contributor': {'id': 2, 'avatar': '', 'nickname': '张同学', 'level': 4},
  });
}
