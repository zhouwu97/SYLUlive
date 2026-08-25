import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/screens/exam_schedule_screen.dart';

void main() {
  setUp(() {
    AppPreferencesStore.setMockInitialValues(<String, Object>{});
  });

  testWidgets('窄屏考试页工具栏不会发生横向溢出', (tester) async {
    for (final width in <double>[432, 360]) {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;

      await tester.pumpWidget(
        const MaterialApp(home: ExamScheduleScreen()),
      );
      await tester.pump();

      final titleRect = tester.getRect(find.byType(DropdownButton<String>));
      final actionRects = [
        tester.getRect(find.byTooltip('桌面小组件')),
        tester.getRect(find.byTooltip('导入存档')),
        tester.getRect(find.byTooltip('导出存档')),
        tester.getRect(find.byTooltip('添加考试')),
      ];

      expect(titleRect.right, lessThanOrEqualTo(actionRects.first.left));
      expect(actionRects.last.right, lessThanOrEqualTo(width));
      expect(tester.takeException(), isNull);
    }

    addTearDown(tester.view.reset);
  });
}
