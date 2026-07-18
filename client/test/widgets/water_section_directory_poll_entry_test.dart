import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/water_section_provider.dart';
import 'package:shenliyuan/screens/water_section_directory_screen.dart';

void main() {
  testWidgets('目录搜索投票关键词显示特殊入口', (tester) async {
    await tester.pumpWidget(ChangeNotifierProvider(create: (_) => WaterSectionProvider(null), child: const MaterialApp(home: WaterSectionDirectoryScreen())));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '投票');
    await tester.pump();
    expect(find.text('校园投票'), findsOneWidget);
    expect(find.text('特殊版块'), findsNothing);
  });
}
