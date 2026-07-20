import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shenliyuan/screens/ai/ai_feature_settings_screen.dart';

void main() {
  testWidgets('AI 功能开关展示七项并持久化关闭状态', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(
      const MaterialApp(home: AIFeatureSettingsScreen()),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SwitchListTile), findsNWidgets(7));
    await tester.tap(find.text('校园 AI 问答'));
    await tester.pumpAndSettle();

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('ai_chat_enabled'), isFalse);
  });
}
