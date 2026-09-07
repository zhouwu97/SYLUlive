import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/edu_credit_requirement.dart';
import 'package:shenliyuan/widgets/edu_grade/academic_requirement_overview.dart';

void main() {
  testWidgets('学分模块 ID 缺失或重复时仍可完整展示', (tester) async {
    final requirements = EduCreditRequirementOverview(
      success: true,
      sourceKind: 'official_credit_requirement',
      sourceUrl: '/credit-requirements',
      parserVersion: 'credit-requirement-v2',
      capturedAt: DateTime(2026, 9, 7),
      structureSignature: null,
      collegeName: null,
      enrollmentGrade: null,
      majorName: null,
      modules: const [
        _TestModule(id: '', name: '公共基础模块'),
        _TestModule(id: '', name: '专业基础模块'),
        _TestModule(id: 'major', name: '专业必修模块'),
        _TestModule(id: 'major', name: '专业选修模块'),
      ],
      improvementCourses: const [],
      status: 'available',
      errorCode: null,
      message: null,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AcademicRequirementOverview(requirements: requirements),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('公共基础模块'), findsOneWidget);
    expect(find.text('专业基础模块'), findsOneWidget);
    expect(find.text('专业必修模块'), findsOneWidget);
    expect(find.text('专业选修模块'), findsOneWidget);
  });
}

class _TestModule extends EduCreditRequirementModule {
  const _TestModule({required super.id, required super.name})
      : super(
          moduleType: 'required',
          requiredCredits: 2,
          requiredCourseCount: null,
          earnedCredits: 1,
          completedCourseCount: 1,
          status: 'in_progress',
          isOptional: false,
          courses: const [],
        );
}
