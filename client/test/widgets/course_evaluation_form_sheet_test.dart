import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/course_evaluation.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/course_evaluation_provider.dart';
import 'package:shenliyuan/widgets/course/course_evaluation_section.dart';

class _LoggedInAuthProvider extends AuthProvider {
  _LoggedInAuthProvider() : super(Dio(), loadStoredAuth: false);

  @override
  User? get user => User(
        id: 1,
        studentId: '20260001',
        nickname: '测试用户',
        createdAt: DateTime(2026),
      );
}

class _ResolvedCourseEvaluationProvider extends CourseEvaluationProvider {
  _ResolvedCourseEvaluationProvider() : super(null);

  static const result = CourseEvaluationResolveResult(
    courseName: '体育',
    teacherName: '体育教师',
    requiresConfirmation: true,
  );

  @override
  CourseEvaluationResolveResult? resolveCacheFor(
    String courseName,
    String teacherName,
  ) =>
      result;
}

void main() {
  testWidgets('课表评价入口和表单使用服务端返回的标准体育学科名', (tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(
            value: _LoggedInAuthProvider(),
          ),
          ChangeNotifierProvider<CourseEvaluationProvider>.value(
            value: _ResolvedCourseEvaluationProvider(),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: CourseEvaluationSection(
              courseName: '体育5',
              teacherName: '体育教师',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('「体育」尚未精确收录，提交前需确认'), findsOneWidget);
    expect(find.textContaining('体育5'), findsNothing);

    await tester.tap(find.text('去确认并评价'));
    await tester.pumpAndSettle();

    expect(find.text('体育'), findsOneWidget);
    expect(find.text('创建新学科「体育」'), findsOneWidget);
    expect(find.textContaining('体育5'), findsNothing);
  });
}
