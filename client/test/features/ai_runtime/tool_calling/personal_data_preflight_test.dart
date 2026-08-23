import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/ai_runtime/tool_calling/personal_data_preflight.dart';

void main() {
  test('分析个人成绩时先规划学业概览读取', () {
    final calls = PersonalDataPreflightPlanner.plan(
      message: '请分析我的成绩风险',
      allowedToolIds: const <String>{'personal.academic.overview'},
      now: DateTime(2026, 8, 23),
    );

    expect(calls, hasLength(1));
    expect(calls.single.tool, 'personal.academic.overview');
  });

  test('非分析型公开问题不读取个人数据', () {
    final calls = PersonalDataPreflightPlanner.plan(
      message: '什么是人工智能？',
      allowedToolIds: const <String>{
        'personal.academic.overview',
        'personal.schedule.week',
      },
      now: DateTime(2026, 8, 23),
    );

    expect(calls, isEmpty);
  });
}
