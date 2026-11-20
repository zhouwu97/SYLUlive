import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/theme/app_colors.dart';
import 'package:shenliyuan/widgets/app_card.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';

void main() {
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  testWidgets('文字弹层与卡片共用新刻度，模糊启停不截断过渡', (tester) async {
    final appearance = ThemeProvider(loadOnStart: false);
    addTearDown(appearance.dispose);
    await appearance.setBackgroundImage('morenbeijing.jpeg');
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: appearance,
      child: MaterialApp(home: Scaffold(body: Builder(builder: (context) {
        return AppCardSurface(
          surfaceOpacity: appTextSheetSurfaceOpacity(context),
          child: const Text('文字弹层'),
        );
      }))),
    ));
    for (final strength in [0.0, .35, 1.0]) {
      await appearance.setFrostedGlassStrength(strength);
      for (final level in [0.0, .25, .5, .75, 1.0]) {
        await appearance.setComponentOpacityLevel(level);
        await tester.pumpAndSettle();
        final card = tester.widget<AppCardSurface>(find.byType(AppCardSurface));
        expect(card.surfaceOpacity, .75 + .25 * level);
      }
    }
    await appearance.setCleanBackgroundMode();
    await tester.pumpAndSettle();
    expect(tester.widget<AppCardSurface>(find.byType(AppCardSurface)).surfaceOpacity, 1);
    expect(tester.takeException(), isNull);
  });
  for (final dark in [false, true]) {
    for (final kind in [
      'surface',
      'card',
      'material',
      'radius-only',
      'course',
      'gradient'
    ]) {
      testWidgets('$kind dark=$dark 关闭模糊也有底面，不重复稀释语义透明度', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone390x844);
        final appearance = ThemeProvider(loadOnStart: false);
        addTearDown(appearance.dispose);
        await appearance.setBackgroundImage('morenbeijing.jpeg');
        await appearance.setComponentOpacityLevel(.6);
        const tint = Color(0x14FF9800);
        const content = SizedBox(key: Key('content'), width: 220, height: 100);
        final surface = switch (kind) {
          'card' =>
            const AppCard(color: tint, margin: EdgeInsets.zero, child: content),
          'material' => const AppCardMaterial(color: tint, child: content),
          'radius-only' => AppCardSurface(
              decoration: const BoxDecoration(
                  borderRadius: BorderRadius.all(Radius.circular(12))),
              child: content),
          'course' =>
            AppCardSurface(color: tint, surfaceOpacity: .45, child: content),
          'gradient' => AppCardSurface(
              decoration: const BoxDecoration(
                  gradient: LinearGradient(colors: [tint, Color(0x0A2196F3)])),
              child: content),
          _ => AppCardSurface(color: tint, child: content),
        };
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: appearance,
          child: GoldenTestApp(
              themeMode: dark ? ThemeMode.dark : ThemeMode.light,
              home: Scaffold(body: Center(child: surface))),
        ));
        final rect = tester.getRect(find.byKey(const Key('content')));
        for (final glass in [false, true, false]) {
          await appearance.setFrostedGlass(glass);
          await tester.pumpAndSettle();
          final alpha = kind == 'course' ? .45 : .9;
          final base = dark
              ? AppColors.surfaceSecondaryDark
              : AppColors.surfaceSecondaryLight;
          if (kind == 'card' || kind == 'material') {
            final material = tester.widget<Material>(find
                .ancestor(
                    of: find.byKey(const Key('content')),
                    matching: find.byType(Material))
                .first);
            expect(material.color,
                Color.alphaBlend(tint, base).withValues(alpha: alpha));
          } else {
            final decoration = tester
                .widget<DecoratedBox>(find
                    .ancestor(
                        of: find.byKey(const Key('content')),
                        matching: find.byType(DecoratedBox))
                    .first)
                .decoration as BoxDecoration;
            if (kind == 'gradient') {
              expect(decoration.gradient!.colors.map((c) => c.a),
                  everyElement(closeTo(alpha, .005)));
            } else {
              expect(
                  decoration.color,
                  kind == 'radius-only'
                      ? base.withValues(alpha: alpha)
                      : Color.alphaBlend(tint, base).withValues(alpha: alpha));
            }
          }
          expect(tester.getRect(find.byKey(const Key('content'))), rect);
          expect(tester.takeException(), isNull);
        }
      });
    }
  }
}
