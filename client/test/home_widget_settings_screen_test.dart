import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shenliyuan/models/home_widget_config.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/screens/home_widget_settings_screen.dart';
import 'package:shenliyuan/services/home_widget_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('字号设置显示三档、默认标准并可立即保存大字号', (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('shenliyuan/widget'),
      (call) async => null,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        home: const HomeWidgetSettingsScreen(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // ListView 只构建当前可视的第一张设置卡，第二张卡在滚动后按同一组件结构构建。
    expect(find.text('字号'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '小'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '标准'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '大'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);

    final courseLargeChip = find.widgetWithText(ChoiceChip, '大').first;
    expect(tester.widget<ChoiceChip>(courseLargeChip).selected, isFalse);

    await tester.tap(courseLargeChip);
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      (await HomeWidgetService.getAppearance(HomeWidgetKind.course)).fontSize,
      HomeWidgetFontSize.large,
    );
    expect(
      (await HomeWidgetService.getAppearance(HomeWidgetKind.exam)).fontSize,
      HomeWidgetFontSize.standard,
    );
    expect(tester.widget<ChoiceChip>(courseLargeChip).selected, isTrue);
  });
}
