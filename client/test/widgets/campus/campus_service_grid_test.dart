import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/campus/campus_service_grid.dart';

Widget _buildGrid({required bool reduceMotion, required VoidCallback onTap}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Scaffold(
        body: CampusServiceGrid(
          isDark: false,
          onEduTap: onTap,
          onCanteenTap: onTap,
          onRateTap: onTap,
          onTeamTap: onTap,
          onMapTap: onTap,
          onCalendarTap: onTap,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('校园服务入口保留点击行为并呈现按压反馈', (tester) async {
    var tapCount = 0;
    await tester.pumpWidget(
      _buildGrid(reduceMotion: false, onTap: () => tapCount++),
    );
    await tester.pump();

    expect(find.text('校园服务'), findsOneWidget);
    expect(find.text('食堂'), findsOneWidget);
    expect(find.text('校园地图'), findsOneWidget);
    expect(find.byType(AnimatedScale), findsNWidgets(6));

    await tester.tap(find.text('校园地图'));
    expect(tapCount, 1);
  });

  testWidgets('食堂入口触发 onCanteenTap', (tester) async {
    var canteenTapCount = 0;
    var otherTapCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CampusServiceGrid(
            isDark: false,
            onEduTap: () => otherTapCount++,
            onCanteenTap: () => canteenTapCount++,
            onRateTap: () => otherTapCount++,
            onTeamTap: () => otherTapCount++,
            onMapTap: () => otherTapCount++,
            onCalendarTap: () => otherTapCount++,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('食堂'));
    expect(canteenTapCount, 1);
    expect(otherTapCount, 0);
  });

  testWidgets('320px 窄屏 3 列布局无溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _buildGrid(reduceMotion: true, onTap: () {}),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('食堂'), findsOneWidget);
  });

  testWidgets('Reduced Motion 保留入口但移除服务项位移与缩放', (tester) async {
    await tester.pumpWidget(
      _buildGrid(reduceMotion: true, onTap: () {}),
    );
    await tester.pump();

    expect(find.text('校园服务'), findsOneWidget);
    expect(find.byType(AnimatedScale), findsNothing);
  });
}
