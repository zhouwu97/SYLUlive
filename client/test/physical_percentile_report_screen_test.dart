import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/physical/physical_percentile_models.dart';
import 'package:shenliyuan/features/physical/physical_percentile_service.dart';
import 'package:shenliyuan/screens/physical_percentile_report_screen.dart';

void main() {
  testWidgets('报告页展示同性别总结并支持切换到缺失样本状态', (tester) async {
    final service = PhysicalPercentileService(
      PhysicalPercentileDataset.fromJson({
        'version': 1,
        'generated_at': '2026-06-27T00:00:00',
        'metrics': {
          'standing_jump': {
            'label': '立定跳远',
            'unit': 'cm',
            'higher_is_better': true,
            'category': 'sport',
          },
          'run_1000m': {
            'label': '1000 米',
            'unit': '秒',
            'higher_is_better': false,
            'category': 'sport',
          },
        },
        'groups': {
          'male': {
            'standing_jump': [200, 220, 220, 260],
            'run_1000m': [230, 260, 260, 300],
          },
          'female': {
            'standing_jump': [150, 170, 190],
          },
          'all': {
            'standing_jump': [150, 170, 190, 200, 220, 220, 260],
            'run_1000m': [230, 260, 260, 300],
          },
        },
      }),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PhysicalPercentileReportScreen(
          scores: const [
            PhysicalRawScore(name: '立定跳远', result: '220'),
            PhysicalRawScore(name: '1000 米跑', result: '260'),
          ],
          gender: PhysicalGender.male,
          serviceOverride: service,
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('超越了多少大学生'), findsOneWidget);
    expect(find.text('体格对比'), findsNothing);
    expect(find.textContaining('你的运动表现超过了同性别'), findsOneWidget);
    expect(find.textContaining('超过 50%'), findsWidgets);

    await tester.tap(find.text('女生'));
    await tester.pumpAndSettle();

    expect(find.textContaining('你的运动表现超过了女生'), findsOneWidget);
    expect(find.text('暂无可比样本'), findsWidgets);
  });
}
