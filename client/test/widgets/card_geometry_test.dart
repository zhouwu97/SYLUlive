import '../helpers/active_backdrop_filters.dart';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/glass_container.dart';

void main() {
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final kind in [
    'surface',
    'material',
    'card',
    'glass',
    'circle',
    'square'
  ]) {
    testWidgets('$kind 开关玻璃保留内容尺寸、圆角和封面裁剪', (tester) async {
      final theme = ThemeProvider(loadOnStart: false);
      addTearDown(theme.dispose);
      await theme.setBackgroundImage('morenbeijing.jpeg');
      final capture = GlobalKey();
      const cover = Key('cover');
      const surface = Key('surface');
      const child = ColoredBox(
          key: cover,
          color: Colors.blue,
          child: SizedBox(width: 160, height: 80));
      final widget = switch (kind) {
        'material' => const AppCardMaterial(key: surface, child: child),
        'card' =>
          const AppCard(key: surface, margin: EdgeInsets.zero, child: child),
        'glass' => const GlassContainer(key: surface, child: child),
        'circle' => AppCardSurface(
            key: surface,
            decoration: const BoxDecoration(
                shape: BoxShape.circle, color: Colors.white),
            child: child),
        'square' => AppCardSurface(
            key: surface,
            decoration: const BoxDecoration(
                borderRadius: BorderRadius.zero, color: Colors.white),
            child: child),
        _ => AppCardSurface(key: surface, color: Colors.white, child: child),
      };
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: theme,
        child: MaterialApp(
            home: Scaffold(
                body: RepaintBoundary(
          key: capture,
          child: ColoredBox(
              color: Colors.red,
              child: SizedBox(
                  width: 200, height: 120, child: Center(child: widget))),
        ))),
      ));
      Rect? previous;
      for (final glass in [false, true, false]) {
        await theme.setFrostedGlass(glass);
        await tester.pumpAndSettle();
        final rect = tester.getRect(find.byKey(cover));
        expect(rect.size, const Size(160, 80));
        if (previous != null) expect(rect, previous);
        previous = rect;
        expect(
            activeBackdropFilters(), glass ? findsOneWidget : findsNothing);
        await tester.runAsync(() async {
          final boundary = capture.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes =
              (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
          final offset =
              ((rect.top.toInt() + 1) * image.width + rect.left.toInt() + 1) *
                  4;
          // 直接以封面填满卡片，圆角处仍必须露出外层红色画布。
          final expected = ['square', 'surface', 'material'].contains(kind)
              ? Colors.blue
              : Colors.red;
          expect(bytes.getUint8(offset), (expected.r * 255).round());
          expect(bytes.getUint8(offset + 2), (expected.b * 255).round());
          image.dispose();
        });
        expect(tester.takeException(), isNull);
      }
    });
  }
}
