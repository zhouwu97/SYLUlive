import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/edu_credit_requirement.dart';
import 'package:shenliyuan/widgets/edu_grade/academic_requirement_card.dart';

void main() {
  testWidgets('学分要求长列表直接布局并只做透明度过渡', (tester) async {
    const module = EduCreditRequirementModule(
      id: 'core',
      name: '核心课程',
      moduleType: 'required',
      requiredCredits: 12,
      requiredCourseCount: 3,
      earnedCredits: 6,
      completedCourseCount: 1,
      status: 'in_progress',
      isOptional: false,
      courses: [
        EduRequirementCourse(
          courseCode: 'CS101',
          courseName: '程序设计基础',
          credits: 4,
          suggestedYear: null,
          suggestedSemester: null,
          actualYear: null,
          actualSemester: null,
          courseNature: null,
          grade: null,
          rawStatus: null,
          remark: null,
          completed: false,
        ),
      ],
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AcademicRequirementCard(module: module)),
      ),
    );

    expect(find.byType(AnimatedSize), findsNothing);
    expect(find.text('程序设计基础'), findsNothing);

    await tester.tap(find.text('核心课程'));
    await tester.pump();

    expect(find.text('程序设计基础'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 160));
  });
}
