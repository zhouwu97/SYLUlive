import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/toolbox_screen.dart';

void main() {
  testWidgets('常用工具包含试卷库入口', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider(loadOnStart: false),
        child: const MaterialApp(home: ToolboxScreen()),
      ),
    );

    expect(find.text('试卷库'), findsOneWidget);
    expect(find.byIcon(Icons.library_books_outlined), findsOneWidget);
  });
}
