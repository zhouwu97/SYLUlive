import '../helpers/active_backdrop_filters.dart';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/frosted_glass.dart';

Future<Uint8List> _pixels(WidgetTester tester, GlobalKey key) async =>
    (await tester.runAsync(() async {
      final image = await (key.currentContext!.findRenderObject()!
              as RenderRepaintBoundary)
          .toImage();
      try {
        return (await image.toByteData())!.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    }))!;

int _filterLayers(Layer layer) {
  var count = layer is BackdropFilterLayer ? 1 : 0;
  if (layer is ContainerLayer) {
    for (Layer? child = layer.firstChild;
        child != null;
        child = child.nextSibling) {
      count += _filterLayers(child);
    }
  }
  return count;
}

void main() {
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  testWidgets('100% 与原滤镜逐像素一致，35% 缩放各方向 sigma，0% 不提交模糊层', (tester) async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    await theme.setFrostedGlass(true);
    final capture = GlobalKey();
    const content = ColoredBox(
      color: Color(0xAAFFFFFF),
      child: SizedBox(width: 140, height: 90),
    );
    Widget fixture(bool original) => ChangeNotifierProvider.value(
          value: theme,
          child: MaterialApp(
            home: RepaintBoundary(
              key: capture,
              child: Stack(fit: StackFit.expand, children: [
                Row(children: [
                  for (var i = 0; i < 20; i++)
                    Expanded(
                        child: ColoredBox(
                            color: i.isEven ? Colors.red : Colors.blue)),
                ]),
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: original
                        ? BackdropFilter(
                            filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 20),
                            blendMode: BlendMode.src,
                            child: content,
                          )
                        : const FrostedGlass(sigmaY: 20, child: content),
                  ),
                ),
              ]),
            ),
          ),
        );
    await tester.pumpWidget(fixture(true));
    await tester.pumpAndSettle();
    final original = await _pixels(tester, capture);
    await tester.pumpWidget(fixture(false));
    await tester.pumpAndSettle();
    expect(await _pixels(tester, capture), orderedEquals(original));
    await theme.setFrostedGlassStrength(.35);
    await tester.pump();
    expect(tester.widget<BackdropFilter>(activeBackdropFilters()).filter,
        ui.ImageFilter.blur(sigmaX: 3.5, sigmaY: 7));
    await theme.setFrostedGlassStrength(0);
    await tester.pump();
    expect(activeBackdropFilters(), findsNothing);
    expect(theme.frostedGlassPerformanceMode, FrostedGlassPerformanceMode.off);
    final boundary =
        capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    expect(_filterLayers(boundary.debugLayer!), 0, reason: '0% 不能提交背景模糊渲染层');
    expect(tester.getSize(find.byWidget(content)), const Size(140, 90));
  });

  for (final kind in ['surface', 'material', 'card']) {
    testWidgets('$kind 调整强度保留材质颜色、形状和内容尺寸', (tester) async {
      final theme = ThemeProvider(loadOnStart: false);
      addTearDown(theme.dispose);
      await theme.setBackgroundImage('morenbeijing.jpeg');
      await theme.setFrostedGlass(true);
      await theme.setComponentOpacity(.7);
      const child = SizedBox(key: Key('content'), width: 160, height: 100);
      final card = switch (kind) {
        'material' => const AppCardMaterial(color: Colors.white, child: child),
        'card' => const AppCard(color: Colors.white, child: child),
        _ => AppCardSurface(color: Colors.white, child: child),
      };
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: theme,
        child: MaterialApp(home: Scaffold(body: Center(child: card))),
      ));
      Rect? geometry;
      ShapeBorder? shape;
      Color? color;
      for (final strength in [1.0, .35, 0.0, .62]) {
        await theme.setFrostedGlassStrength(strength);
        await tester.pumpAndSettle();
        final rect = tester.getRect(find.byKey(const Key('content')));
        final currentShape = kind == 'card' && strength == 0
            ? tester.widget<Card>(find.byType(Card)).shape!
            : (tester.widget<ClipPath>(find.byType(ClipPath).first).clipper!
                    as ShapeBorderClipper)
                .shape;
        final currentColor = kind == 'surface'
            ? (tester
                    .widget<DecoratedBox>(find.byType(DecoratedBox).first)
                    .decoration as BoxDecoration)
                .color!
            : tester
                .widget<Material>(find
                    .ancestor(
                        of: find.byKey(const Key('content')),
                        matching: find.byType(Material))
                    .first)
                .color!;
        geometry ??= rect;
        shape ??= currentShape;
        color ??= currentColor;
        expect(rect, geometry);
        expect(currentShape, shape);
        expect(currentColor, color);
        expect(currentColor.a, closeTo(.7, .01));
        if (strength == 0) {
          expect(activeBackdropFilters(), findsNothing);
        } else {
          expect(tester.widget<BackdropFilter>(activeBackdropFilters()).enabled,
              isTrue);
        }
      }
    });
  }
}
