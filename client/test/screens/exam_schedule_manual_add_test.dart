import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/exam_schedule_screen.dart';
import 'package:shenliyuan/services/exam_schedule_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('手动添加考试会关闭弹窗并持久化', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider(loadOnStart: false),
        child: const MaterialApp(home: ExamScheduleScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('添加考试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('手动添加'));
    await tester.pumpAndSettle();

    final nameField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == '科目名称',
    );
    final locationField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == '考试地点',
    );
    await tester.enterText(nameField, '组件测试考试');
    await tester.enterText(locationField, '测试教室');
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pumpAndSettle();

    expect(find.text('添加考试'), findsNothing);
    expect(find.text('组件测试考试'), findsOneWidget);

    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(ExamScheduleRepository.localExamsKey);
    final saved = jsonDecode(encoded!) as List<dynamic>;
    expect(saved, hasLength(1));
    expect(saved.single['name'], '组件测试考试');
    expect(saved.single['location'], '测试教室');
    expect(
      DateTime.parse(saved.single['endTime'] as String),
      isA<DateTime>().having(
        (end) => end.isAfter(
          DateTime.parse(saved.single['startTime'] as String),
        ),
        '晚于开始时间',
        isTrue,
      ),
    );
  });
}
