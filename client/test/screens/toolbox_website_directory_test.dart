import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/toolbox_screen.dart';

Widget _buildToolboxScreen() {
  return ChangeNotifierProvider<ThemeProvider>(
    create: (_) => ThemeProvider(loadOnStart: false),
    child: const MaterialApp(
      home: ToolboxScreen(),
    ),
  );
}

void main() {
  testWidgets('网站大全进入独立页面并展示真实网站列表', (tester) async {
    await tester.pumpWidget(_buildToolboxScreen());

    await tester.tap(find.text('网站大全'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    expect(find.text('省大创平台'), findsOneWidget);
    expect(find.text('教务处'), findsOneWidget);
    expect(find.text('创院'), findsOneWidget);

    for (final title in ['查二课', '图书馆', '沈理就业网']) {
      await tester.scrollUntilVisible(
        find.text(title),
        240,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text(title), findsOneWidget);
    }
  });
}
