import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/app_choice_chip.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  testWidgets('玻璃芯片保留原标签位置、绘制范围和留白点击区', (tester) async {
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    final appearance = ThemeProvider(loadOnStart: false);
    addTearDown(appearance.dispose);
    const chipKey = Key('chip');
    var selected = false;
    late Rect nativeMaterial;
    Widget fixture(bool glass) => ChangeNotifierProvider.value(
          value: appearance,
          child: GoldenTestApp(
              home: Scaffold(
                  body: Center(
            child: glass
                ? AppChoiceChip(
                    key: chipKey,
                    label: const Text('筛选'),
                    selected: selected,
                    onSelected: (value) => selected = value)
                : ChoiceChip(
                    key: chipKey,
                    label: const Text('筛选'),
                    selected: selected,
                    onSelected: (value) => selected = value),
          ))),
        );
    await tester.pumpWidget(fixture(false));
    final nativeTarget = tester.getRect(find.byKey(chipKey));
    final nativeLabel = tester.getRect(find.text('筛选'));
    nativeMaterial = tester.getRect(find
        .descendant(of: find.byKey(chipKey), matching: find.byType(Material))
        .first);
    await appearance.setFrostedGlass(true);
    await tester.pumpWidget(fixture(true));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(chipKey)), nativeTarget);
    expect(tester.getRect(find.text('筛选')), nativeLabel);
    expect(find.text('筛选').hitTestable(), findsOneWidget);
    expect(
        tester.getRect(find.descendant(
            of: find.byKey(chipKey), matching: find.byType(AppCardSurface))),
        nativeMaterial,
        reason: '玻璃只覆盖原芯片底面，不能填满额外的触控留白');
    await tester.tapAt(Offset(nativeTarget.center.dx, nativeTarget.top + 1));
    await tester.pumpAndSettle();
    expect(selected, isTrue, reason: '材质缩回原表面后仍保留完整触控区');
    expect(tester.takeException(), isNull);
  });
  for (final direction in TextDirection.values) {
    testWidgets('卡片材质沿用 Container 的边框与内容 inset $direction', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final appearance = ThemeProvider(loadOnStart: false);
      addTearDown(appearance.dispose);
      const decoration = BoxDecoration(
        color: Colors.white,
        border: BorderDirectional(
          start: BorderSide(width: 3),
          end: BorderSide(width: 1),
          top: BorderSide(width: 2),
          bottom: BorderSide(width: 4),
        ),
      );
      const padding = EdgeInsetsDirectional.fromSTEB(12, 8, 20, 16);
      const content = SizedBox(key: Key('content'), width: 80, height: 40);
      Widget fixture(Widget child) => ChangeNotifierProvider.value(
            value: appearance,
            child: GoldenTestApp(
                home: Scaffold(
                    body: Directionality(
              textDirection: direction,
              child: Align(alignment: Alignment.topLeft, child: child),
            ))),
          );
      await tester.pumpWidget(fixture(Container(
        margin: const EdgeInsets.all(10),
        padding: padding,
        decoration: decoration,
        child: content,
      )));
      final original = tester.getRect(find.byKey(const Key('content')));
      await tester.pumpWidget(fixture(AppCardSurface(
        margin: const EdgeInsets.all(10),
        padding: padding,
        decoration: decoration,
        child: content,
      )));
      for (final glass in [false, true, false]) {
        await appearance.setFrostedGlass(glass);
        await tester.pumpAndSettle();
        expect(tester.getRect(find.byKey(const Key('content'))), original);
        expect(tester.takeException(), isNull);
      }
    });
  }
}
