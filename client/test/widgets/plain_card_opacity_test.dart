import '../helpers/active_backdrop_filters.dart';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/theme/app_colors.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/glass_container.dart';

void main() {
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  for (final dark in [false, true]) {
    for (final kind in ['surface', 'card', 'material']) {
      testWidgets('默认底色在玻璃启停后保持一致 $kind dark=$dark', (tester) async {
        final theme = ThemeProvider(loadOnStart: false);
        addTearDown(theme.dispose);
        await theme.setBackgroundImage('morenbeijing.jpeg');
        await theme.setComponentOpacityLevel(.6);
        const content = SizedBox(
            key: ValueKey('default-fill-content'), width: 180, height: 90);
        final card = switch (kind) {
          'card' => const AppCard(
              margin: EdgeInsets.zero, elevation: 0, child: content),
          'material' => const AppCardMaterial(child: content),
          _ => AppCardSurface(child: content),
        };
        final capture = GlobalKey();
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: theme,
          child: MaterialApp(
            theme: dark ? ThemeData.dark() : ThemeData.light(),
            home: Scaffold(
              body: RepaintBoundary(
                key: capture,
                child: ColoredBox(
                  color: Colors.red,
                  child: SizedBox(
                      width: 260, height: 160, child: Center(child: card)),
                ),
              ),
            ),
          ),
        ));
        final base = dark
            ? AppColors.surfaceSecondaryDark
            : AppColors.surfaceSecondaryLight;
        final expected =
            Color.alphaBlend(base.withValues(alpha: .9), Colors.red);
        Rect? before;
        for (final glass in [false, true, false]) {
          await theme.setFrostedGlass(glass);
          await tester.pumpAndSettle();
          final rect = tester
              .getRect(find.byKey(const ValueKey('default-fill-content')));
          before ??= rect;
          expect(rect, before);
          final color = await tester.runAsync(() async {
            final image = await (capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
            try {
              final pixels = (await image.toByteData())!;
              final p = (80 * image.width + 130) * 4;
              return Color.fromARGB(pixels.getUint8(p + 3), pixels.getUint8(p),
                  pixels.getUint8(p + 1), pixels.getUint8(p + 2));
            } finally {
              image.dispose();
            }
          });
          for (final channel in [
            (color!.r, expected.r),
            (color.g, expected.g),
            (color.b, expected.b),
          ]) {
            expect(channel.$1, closeTo(channel.$2, 2 / 255),
                reason: '同一张默认卡片只能切换模糊，不能换成另一种 Material 底色');
          }
          expect(tester.takeException(), isNull);
        }
      });
    }
  }
  for (final dark in [false, true]) {
    for (final kind in ['surface', 'card', 'material', 'glass']) {
      testWidgets('关闭玻璃 $kind 仍可调不透明度且不改变内容和圆角 dark=$dark', (tester) async {
        final theme = ThemeProvider(loadOnStart: false);
        addTearDown(theme.dispose);
        await theme.setBackgroundImage('morenbeijing.jpeg');
        const content =
            SizedBox(key: ValueKey('content'), width: 180, height: 90);
        final card = switch (kind) {
          'card' => const AppCard(
              color: Colors.white,
              elevation: 0,
              surfaceTintColor: Colors.transparent,
              margin: EdgeInsets.zero,
              child: content),
          'material' =>
            const AppCardMaterial(color: Colors.white, child: content),
          'glass' =>
            const GlassContainer(backgroundColor: Colors.white, child: content),
          _ => AppCardSurface(color: Colors.white, child: content),
        };
        final capture = GlobalKey();
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: theme,
          child: MaterialApp(
            theme: dark ? ThemeData.dark() : ThemeData.light(),
            home: Scaffold(
                body: RepaintBoundary(
                    key: capture,
                    child: ColoredBox(
                        color: Colors.red,
                        child: SizedBox(
                            width: 260,
                            height: 160,
                            child: Center(child: card))))),
          ),
        ));
        Rect? previous;
        final levels = <int>[];
        for (final level in [.4, .75, 1.0]) {
          await theme.setComponentOpacityLevel(level);
          await tester.pumpAndSettle();
          final rect = tester.getRect(find.byKey(const ValueKey('content')));
          previous ??= rect;
          expect(rect, previous);
          expect(activeBackdropFilters(), findsNothing);
          final color = kind == 'surface' || kind == 'glass'
              ? (tester
                      .widget<DecoratedBox>(find.byType(DecoratedBox).first)
                      .decoration as BoxDecoration)
                  .color!
              : kind == 'card'
                  ? tester.widget<Card>(find.byType(Card)).color!
                  : tester
                      .widget<Material>(find
                          .ancestor(
                              of: find.byKey(const ValueKey('content')),
                              matching: find.byType(Material))
                          .first)
                      .color!;
          expect(color.a, closeTo(.75 + .25 * level, .01));
          final blue = await tester.runAsync(() async {
            final image = await (capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
            try {
              final bytes =
                  (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
              return bytes.getUint8((80 * image.width + 130) * 4 + 2);
            } finally {
              image.dispose();
            }
          });
          levels.add(blue!);
          expect(tester.takeException(), isNull);
        }
        expect(levels[0], lessThan(levels[1]));
        expect(levels[1], lessThan(levels[2]));
        expect(levels[2], 255);
      });
    }
  }
}
