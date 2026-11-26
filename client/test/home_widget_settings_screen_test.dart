import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shenliyuan/models/home_widget_config.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/screens/home_widget_settings_screen.dart';
import 'package:shenliyuan/services/home_widget_service.dart';
import 'package:shenliyuan/theme/app_text_scaler.dart';
import 'helpers/golden_viewport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('同一帧修改主题和字号不会互相覆盖', (tester) async {
    await setGoldenViewport(tester, GoldenViewports.phone390x844);
    AppPreferencesStore.setMockInitialValues({});
    final writes = <Map<Object?, Object?>>[];
    const channel = MethodChannel('shenliyuan/widget');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'updateWidget') {
        writes.add(Map<Object?, Object?>.from(call.arguments as Map));
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester
        .pumpWidget(const MaterialApp(home: HomeWidgetSettingsScreen()));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '校园蓝').first);
    // 不 pump：两个回调来自同一份旧 widget 树，验证第二次修改读取最新选择。
    await tester.tap(find.widgetWithText(ChoiceChip, '超大').first);
    await tester.pumpAndSettle();
    final appearance =
        await HomeWidgetService.getAppearance(HomeWidgetKind.course);
    expect(appearance.theme, HomeWidgetTheme.campusBlue);
    expect(appearance.fontSize, HomeWidgetFontSize.extraLarge);
    expect(appearance.frostedGlass, isTrue);
    expect(
        (await HomeWidgetService.getAppearance(HomeWidgetKind.exam))
            .frostedGlass,
        isFalse);
    expect(writes.last['course_theme'], 'campusBlue');
    expect(writes.last['course_font_size'], 'extraLarge');
    expect(writes.last['course_frosted_glass'], isTrue);
    expect(writes.last['exam_frosted_glass'], isFalse);
    expect(tester.takeException(), isNull);
    await HomeWidgetService.updateAppearance(appearance);
  });

  testWidgets('原生刷新失败后，换色选中项仍与已保存的设置一致', (tester) async {
    await setGoldenViewport(tester, GoldenViewports.phone390x844);
    AppPreferencesStore.setMockInitialValues({});
    const channel = MethodChannel('shenliyuan/widget');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'updateWidget') {
        throw PlatformException(code: 'WIDGET_UPDATE_FAILED');
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester
        .pumpWidget(const MaterialApp(home: HomeWidgetSettingsScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '校园蓝').first);
    await tester.pumpAndSettle();
    final saved = await HomeWidgetService.getAppearance(HomeWidgetKind.course);
    expect(saved.theme, HomeWidgetTheme.campusBlue);
    expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '校园蓝').first)
            .selected,
        isTrue);
  });

  for (final appGroupUnavailable in [false, true]) {
    testWidgets('同步全部失败显示原因，按钮恢复后可重试：AppGroup=$appGroupUnavailable',
        (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone390x844);
      AppPreferencesStore.setMockInitialValues({});
      var failRefresh = true;
      const channel = MethodChannel('shenliyuan/widget');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
          (call) async {
        if (call.method == 'updateWidget' && failRefresh) {
          throw PlatformException(
            code: appGroupUnavailable
                ? 'WIDGET_APP_GROUP_UNAVAILABLE'
                : 'WIDGET_UPDATE_FAILED',
            message: appGroupUnavailable
                ? '小组件共享存储不可用，请使用主 App 与小组件均具有相同 App Group 权限的签名重新安装'
                : null,
          );
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      await tester
          .pumpWidget(const MaterialApp(home: HomeWidgetSettingsScreen()));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('同步全部小组件'), 400);
      await tester.tap(find.text('同步全部小组件'));
      await tester.pumpAndSettle();
      expect(find.text('全部桌面小组件已同步'), findsNothing);
      expect(
          find.descendant(
              of: find.byType(SnackBar),
              matching: find.text(appGroupUnavailable
                  ? '小组件共享存储不可用，请使用主 App 与小组件均具有相同 App Group 权限的签名重新安装'
                  : '小组件同步失败，请检查状态后重试')),
          findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, '同步全部小组件'))
              .onPressed,
          isNotNull);
      failRefresh = false;
      await tester.tap(find.text('同步全部小组件'));
      await tester.pumpAndSettle();
      expect(find.text('全部桌面小组件已同步'), findsOneWidget);
      expect(find.text('小组件状态：已同步'), findsOneWidget);
    });
  }

  for (final large in [false, true]) {
    testWidgets('有课预览各主题及字号不溢出，包含超大 2×2／4×2 large=$large', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone390x844);
      AppPreferencesStore.setMockInitialValues({
        'widget_course_data': jsonEncode({
          'schema_version': 1,
          'courses': [
            for (var i = 1; i <= 2; i++)
              {
                'name': '课程$i',
                'time': '08:00-09:40',
                'location': 'A-310',
                'teacher': '测试教师',
                'color': '#3B82F6'
              },
          ]
        }),
      });
      const channel = MethodChannel('shenliyuan/widget');
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                  textScaler: AppTextScaler(
                      TextScaler.linear(large ? 1.3 : 1), large ? 1.3 : 1)),
              child: child!),
          home: const HomeWidgetSettingsScreen()));
      await tester.pumpAndSettle();
      for (final theme in ['跟随系统', '浅色', '深色', '校园蓝']) {
        await Scrollable.ensureVisible(
            tester.element(find.widgetWithText(ChoiceChip, theme).first),
            alignment: 0.5);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ChoiceChip, theme).first);
        await tester.pumpAndSettle();
        for (final font in ['小', '标准', '大', '超大']) {
          await Scrollable.ensureVisible(
              tester.element(find.widgetWithText(ChoiceChip, font).first),
              alignment: 0.5);
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(ChoiceChip, font).first);
          await tester.pumpAndSettle();
          expect(
              tester
                  .widget<ChoiceChip>(
                      find.widgetWithText(ChoiceChip, font).first)
                  .selected,
              isTrue);
          expect(find.text('课程1'), findsOneWidget);
          expect(find.text('课程2'), findsOneWidget);
          expect(tester.takeException(), isNull, reason: '$theme / $font');
        }
      }
      await Scrollable.ensureVisible(tester.element(find.text('4×2').first),
          alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tap(find.text('4×2').first);
      await tester.pumpAndSettle();
      expect(find.text('课程1'), findsOneWidget);
      expect(find.text('课程2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await HomeWidgetService.updateAppearance(
          await HomeWidgetService.getAppearance(HomeWidgetKind.course));
    });
  }

  testWidgets('字号设置显示四档、默认标准并可立即保存超大字号', (tester) async {
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
    expect(find.widgetWithText(ChoiceChip, '超大'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);

    final courseExtraLargeChip = find.widgetWithText(ChoiceChip, '超大').first;
    expect(tester.widget<ChoiceChip>(courseExtraLargeChip).selected, isFalse);

    await Scrollable.ensureVisible(tester.element(courseExtraLargeChip),
        alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(courseExtraLargeChip);
    await tester.pumpAndSettle();

    expect(
      (await HomeWidgetService.getAppearance(HomeWidgetKind.course)).fontSize,
      HomeWidgetFontSize.extraLarge,
    );
    expect(
      (await HomeWidgetService.getAppearance(HomeWidgetKind.exam)).fontSize,
      HomeWidgetFontSize.standard,
    );
    expect(tester.widget<ChoiceChip>(courseExtraLargeChip).selected, isTrue);
    expect(find.textContaining('2×2 紧凑显示 2 条'), findsOneWidget);
  });
}
