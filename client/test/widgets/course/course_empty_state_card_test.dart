import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/course/course_empty_state_card.dart';

void main() {
  testWidgets('大字号下未登录课表入口改用两列并保持可读', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CourseEmptyStateCard(
                type: CourseEmptyStateType.unlogged,
                isDark: false,
                onMainAction: _noop,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(Wrap), findsOneWidget);
    expect(find.text('桌面小组件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('大字号深色模式下功能入口仍保持两列布局', (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: CourseEmptyStateCard(
                type: CourseEmptyStateType.unlogged,
                isDark: true,
                onMainAction: _noop,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(Wrap), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

void _noop() {}
