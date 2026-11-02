import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/course/course_empty_state_card.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import '../../helpers/golden_test_app.dart';
import '../../helpers/golden_viewport.dart';
import '../../helpers/load_test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  for (final type in [
    CourseEmptyStateType.unlogged,
    CourseEmptyStateType.noCache
  ]) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('课表说明和功能内容有底面且不移动 $type dark=$dark scale=$scale',
            (tester) async {
          await setGoldenViewport(tester, GoldenViewports.phone390x844);
          AppPreferencesStore.setMockInitialValues({});
          final appearance = ThemeProvider(loadOnStart: false);
          addTearDown(appearance.dispose);
          await appearance.setBackgroundImage('morenbeijing.jpeg');
          await appearance.setComponentOpacity(.75);
          await tester.pumpWidget(ChangeNotifierProvider.value(
            value: appearance,
            child: GoldenTestApp(
                themeMode: dark ? ThemeMode.dark : ThemeMode.light,
                textScaler: TextScaler.linear(scale),
                home: Scaffold(
                    body: SingleChildScrollView(
                        child: CourseEmptyStateCard(
                  type: type,
                  isDark: dark,
                  onMainAction: _noop,
                )))),
          ));
          await tester.pumpAndSettle();
          final hints = type == CourseEmptyStateType.unlogged
              ? ['登录并绑定教务系统后即可解锁以上功能', '桌面小组件', '上课提醒']
              : ['1 选择学期  ·  2 预览课程  ·  3 设置开学第一周'];
          for (final label in hints) {
            final text = find.text(label);
            final rect = tester.getRect(text);
            expect(
                find.ancestor(
                    of: text, matching: find.byType(AppContentSurface)),
                findsOneWidget);
            for (final glass in [true, false]) {
              await appearance.setFrostedGlass(glass);
              await tester.pumpAndSettle();
              expect(tester.getRect(text), rect);
              expect(tester.widget<Text>(text).style!.color,
                  Theme.of(tester.element(text)).colorScheme.onSurfaceVariant);
              expect(tester.takeException(), isNull);
            }
          }
        });
      }
    }
  }

  testWidgets('大字号下未登录课表入口改用两列并保持可读', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(1.5)),
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
          home: const Scaffold(
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
