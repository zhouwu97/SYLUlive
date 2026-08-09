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
    expect(find.text('校园地图'), findsOneWidget);
    expect(find.byType(AnimatedScale), findsNWidgets(5));

    await tester.tap(find.text('校园地图'));
    expect(tapCount, 1);
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
