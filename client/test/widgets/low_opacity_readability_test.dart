import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/settings/frosted_glass_settings_screen.dart';
import 'package:shenliyuan/theme/app_colors.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/glass_container.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';
import '../helpers/surface_test_theme.dart';

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final dark in [false, true]) {
    for (final glass in [false, true]) {
      testWidgets('卡片全区间按实际像素连续调节 dark=$dark glass=$glass', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone390x844);
        final theme = SurfaceTestTheme();
        addTearDown(theme.dispose);
        await theme.setBackgroundImage('morenbeijing.jpeg');
        await theme.setFrostedGlass(glass);
        await theme.setComponentOpacityLevel(0);
        final capture = GlobalKey();
        final backdrop = Color.alphaBlend(
          dark
              ? Colors.black.withValues(alpha: .35)
              : Colors.white.withValues(alpha: .25),
          dark ? Colors.white : Colors.black,
        );
        Widget content(String kind) => Builder(builder: (context) {
              final scheme = Theme.of(context).colorScheme;
              return SizedBox(
                key: ValueKey(kind),
                width: 320,
                height: 110,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('校园生活 · 正文保持清晰',
                          style: TextStyle(color: scheme.onSurface)),
                      Text('加载、空数据与失败提示也需要清楚可读',
                          style: TextStyle(
                              color: scheme.onSurfaceVariant, fontSize: 12)),
                    ],
                  ),
                ),
              );
            });
        await tester.pumpWidget(ChangeNotifierProvider<ThemeProvider>.value(
          value: theme,
          child: GoldenTestApp(
            themeMode: dark ? ThemeMode.dark : ThemeMode.light,
            home: Scaffold(
              body: RepaintBoundary(
                key: capture,
                // 使用与页面背景相同的明暗遮罩，并选取最不利的纯色壁纸。
                child: ColoredBox(
                  color: backdrop,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 12,
                      children: [
                        AppCardSurface(child: content('surface')),
                        AppCard(
                            margin: EdgeInsets.zero, child: content('card')),
                        AppCardMaterial(child: content('material')),
                        GlassContainer(child: content('glass')),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();

        final samples = <String, List<int>>{};
        Color? glassShadowBackdrop;
        if (!glass) {
          theme.setSurfacesHidden(true);
          await tester.pumpAndSettle();
          glassShadowBackdrop = await tester.runAsync(() async {
            final image = await (capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
            try {
              final bytes = (await image.toByteData())!;
              final rect = tester.getRect(find.byKey(const ValueKey('glass')));
              final offset = ((rect.bottom.round() - 16) * image.width +
                      rect.center.dx.round()) *
                  4;
              return Color.fromARGB(255, bytes.getUint8(offset),
                  bytes.getUint8(offset + 1), bytes.getUint8(offset + 2));
            } finally {
              image.dispose();
            }
          });
          theme.setSurfacesHidden(false);
        }
        for (final level in [0.0, .1, .25, .4, .5, .55, .7, .75, .95, 1.0]) {
          final opacity = .75 + .25 * level;
          await theme.setComponentOpacityLevel(level);
          await tester.pumpAndSettle();
          final image = (await tester.runAsync(() async =>
              (capture.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage()))!;
          try {
            final data = (await tester.runAsync(
                () => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
            for (final kind in ['surface', 'card', 'material', 'glass']) {
              final rect = tester.getRect(find.byKey(ValueKey(kind)));
              final offset = ((rect.bottom.round() - 16) * image.width +
                      rect.center.dx.round()) *
                  4;
              final background = Color.fromARGB(255, data.getUint8(offset),
                  data.getUint8(offset + 1), data.getUint8(offset + 2));
              final expected = Color.alphaBlend(
                  (dark
                          ? AppColors.surfaceSecondaryDark
                          : AppColors.surfaceSecondaryLight)
                      .withValues(alpha: opacity),
                  kind == 'glass' && !glass ? glassShadowBackdrop! : backdrop);
              for (final channel in [
                (background.r, expected.r),
                (background.g, expected.g),
                (background.b, expected.b),
              ]) {
                expect(channel.$1, closeTo(channel.$2, 2 / 255),
                    reason: '$kind 在档位 $level 必须准确绘制 $opacity 的底色');
              }
              // 用实际八位通道检查低区间也有可见变化。
              samples
                  .putIfAbsent(kind, () => [])
                  .add((background.r * 255).round());
            }
            final directory = Platform.environment['CARD_READABILITY_QA_DIR'];
            if (directory != null && [0.0, .5, 1.0].contains(level)) {
              await tester.runAsync(() async {
                await Directory(directory).create(recursive: true);
                final png =
                    (await image.toByteData(format: ui.ImageByteFormat.png))!;
                await File('$directory/cards-dark-$dark-glass-$glass-level-${(level * 100).round()}.png')
                    .writeAsBytes(png.buffer.asUint8List());
              });
            }
          } finally {
            image.dispose();
          }
          expect(theme.componentOpacity, opacity, reason: '可读性保护不能覆盖用户保存的偏好');
          expect(theme.componentOpacityLevel, closeTo(level, 1e-12));
          expect(tester.takeException(), isNull);
        }
        for (final values in samples.values) {
          for (var i = 1; i < values.length; i++) {
            expect(values[i],
                dark ? lessThan(values[i - 1]) : greaterThan(values[i - 1]),
                reason: '新刻度各段均应改变底色');
          }
        }
      });
    }
  }

  for (final dark in [false, true]) {
    for (final large in [false, true]) {
      testWidgets('真实卡片设置页低值可读且可连续拖动 dark=$dark large=$large', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone360x800);
        final theme = ThemeProvider(loadOnStart: false);
        addTearDown(theme.dispose);
        await theme.setBackgroundImage('morenbeijing.jpeg');
        await theme.setComponentOpacityLevel(0);
        await theme.setFrostedGlass(true);
        final capture = GlobalKey();
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: theme,
          child: RepaintBoundary(
            key: capture,
            child: GoldenTestApp(
              themeMode: dark ? ThemeMode.dark : ThemeMode.light,
              textScaler:
                  large ? const TextScaler.linear(1.3) : TextScaler.noScaling,
              home: const FrostedGlassSettingsScreen(),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        final wallpaper = tester.widget<Image>(find.byType(Image).first).image;
        await tester
            .runAsync(() => precacheImage(wallpaper, capture.currentContext!));
        await tester.pumpAndSettle();
        expect(find.text('调节卡片底色的通透程度'), findsOneWidget);
        expect(find.textContaining('底色按 75%'), findsNothing);
        final slider = find.descendant(
            of: find.byKey(const ValueKey('card-opacity')),
            matching: find.byType(Slider));
        expect(tester.widget<Slider>(slider).value, 0);
        final state = tester.state(slider);
        final directory = Platform.environment['CARD_READABILITY_QA_DIR'];
        if (directory != null) {
          await tester.runAsync(() async {
            final image = await (capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
            try {
              await Directory(directory).create(recursive: true);
              final data =
                  (await image.toByteData(format: ui.ImageByteFormat.png))!;
              await File('$directory/settings-dark-$dark-large-$large.png')
                  .writeAsBytes(data.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
        final rect = tester.getRect(slider);
        final gesture = await tester.startGesture(rect.centerLeft);
        await gesture.moveTo(rect.centerRight);
        await tester.pumpAndSettle();
        expect(theme.componentOpacity, 1);
        await gesture.moveTo(rect.centerLeft);
        await tester.pumpAndSettle();
        await gesture.up();
        await tester.pumpAndSettle();
        expect(theme.componentOpacity, .75);
        expect(theme.componentOpacityLevel, 0);
        expect(tester.state(slider), same(state));
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final dark in [false, true]) {
    testWidgets('卡片在同色背景上不给文字和图标增加轮廓 dark=$dark', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone390x844);
      final theme = ThemeProvider(loadOnStart: false);
      addTearDown(theme.dispose);
      await theme.setBackgroundImage('morenbeijing.jpeg');
      await theme.setComponentOpacityLevel(0);
      final ink = dark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight;
      final capture = GlobalKey();
      Widget text() =>
          Text('可读 Aa', style: TextStyle(color: ink, fontSize: 24));
      Widget icon() => Icon(Icons.settings, color: ink, size: 32);
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: theme,
        child: GoldenTestApp(
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          home: Scaffold(
            body: RepaintBoundary(
              key: capture,
              child: ColoredBox(
                color: ink,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 20,
                    children: [
                      SizedBox(
                          key: const ValueKey('plain-text'),
                          width: 300,
                          height: 70,
                          child: text()),
                      AppCardSurface(
                          key: const ValueKey('card-text'),
                          color: ink,
                          width: 300,
                          height: 70,
                          child: text()),
                      SizedBox(
                          key: const ValueKey('plain-icon'),
                          width: 300,
                          height: 70,
                          child: icon()),
                      AppCardSurface(
                          key: const ValueKey('card-icon'),
                          color: ink,
                          width: 300,
                          height: 70,
                          child: icon()),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final image = await (capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary)
            .toImage();
        try {
          final data =
              (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
          int visiblePixels(String key) {
            final rect = tester.getRect(find.byKey(ValueKey(key)));
            var count = 0;
            for (var y = rect.top.round(); y < rect.bottom.round(); y++) {
              for (var x = rect.left.round(); x < rect.right.round(); x++) {
                final offset = (y * image.width + x) * 4;
                if ((data.getUint8(offset) - ink.r * 255).abs() +
                        (data.getUint8(offset + 1) - ink.g * 255).abs() +
                        (data.getUint8(offset + 2) - ink.b * 255).abs() >
                    80) {
                  count++;
                }
              }
            }
            return count;
          }

          expect(visiblePixels('plain-text'), 0, reason: '同色背景下原始文字应无法辨认');
          expect(visiblePixels('plain-icon'), 0);
          expect(visiblePixels('card-text'), 0,
              reason: '低不透明度不能给文字加上浅色或深色轮廓');
          expect(visiblePixels('card-icon'), 0,
              reason: '图标应沿用主题前景绘制');
        } finally {
          image.dispose();
        }
      });
      expect(tester.takeException(), isNull);
    });
  }
}
