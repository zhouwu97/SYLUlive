import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/edu_grade/grade_summary_card.dart';
import '../../helpers/golden_viewport.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('成绩缓存时间和刷新状态在大字号下不溢出：$brightness', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
            body: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: GradeSummaryCard(
              selectedYear: '2026',
              selectedSemester: 3,
              grades: const [],
              hasValidData: true,
              isRefreshing: true,
              updatedAt: DateTime(2026, 9, 8, 22, 30)),
        )),
      ));
      expect(find.textContaining('0 门课程'), findsOneWidget);
      expect(find.textContaining('上次更新 9月8日 22:30'), findsOneWidget);
      expect(find.textContaining('正在连接教务'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
