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

class _Stripes extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    for (var x = 0.0; x < size.width; x += 4) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 4, size.height),
          Paint()..color = (x ~/ 4).isEven ? Colors.white : Colors.black);
    }
  }

  @override
  bool shouldRepaint(_Stripes oldDelegate) => false;
}

void main() {
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  testWidgets('关闭模糊时渐变只应用一次透明度，保留装饰、课表和透明容器', (tester) async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    await theme.setComponentOpacity(.4);
    const decoration = BoxDecoration(
      gradient: LinearGradient(
        colors: [Color(0x146366F1), Color(0x0A8B5CF6)],
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
        stops: [.2, .8],
      ),
      border: Border.fromBorderSide(BorderSide(color: Colors.blue)),
      boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
      borderRadius: BorderRadius.all(Radius.circular(16)),
    );
    const courseDecoration = BoxDecoration(color: Color(0x33FF0000));
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: theme,
      child: MaterialApp(
          home: Scaffold(
              body: Column(children: [
        AppCardSurface(
          key: const ValueKey('gradient'),
          height: 80,
          blur: 0,
          decoration: decoration,
        ),
        AppCardSurface(
          key: const ValueKey('course'),
          height: 80,
          surfaceOpacity: .2,
          decoration: courseDecoration,
        ),
        const AppCardMaterial(
          color: Colors.transparent,
          child: SizedBox(height: 40),
        ),
        const AppCardMaterial(
          type: MaterialType.transparency,
          child: SizedBox(height: 40),
        ),
      ]))),
    ));
    BoxDecoration surface(String key) => tester
        .widget<Container>(
          find
              .descendant(
                  of: find.byKey(ValueKey(key)),
                  matching: find.byType(Container))
              .first,
        )
        .decoration! as BoxDecoration;
    void check() {
      final actual = surface('gradient');
      final gradient = actual.gradient! as LinearGradient;
      expect(actual.border, decoration.border);
      expect(actual.boxShadow, decoration.boxShadow);
      expect(actual.borderRadius, decoration.borderRadius);
      expect(gradient.begin, Alignment.topRight);
      expect(gradient.end, Alignment.bottomLeft);
      expect(gradient.stops, [.2, .8]);
      expect(
          gradient.colors,
          decoration.gradient!.colors
              .map((color) =>
                  Color.alphaBlend(color, AppColors.surfaceSecondaryLight)
                      .withValues(alpha: .4))
              .toList());
    }

    check();
    expect(surface('course'), courseDecoration);
    final materials = tester
        .widgetList<Material>(find.descendant(
          of: find.byType(AppCardMaterial),
          matching: find.byType(Material),
        ))
        .toList();
    expect(materials.first.color, Colors.transparent);
    expect(materials.last.type, MaterialType.transparency);
    expect(find.byType(BackdropFilter), findsNothing);
    await theme.setFrostedGlass(true);
    await tester.pumpAndSettle();
    check(); // blur=0 同样服从卡片透明度。
    await theme.setFrostedGlass(false);
    await theme.setCleanBackgroundMode();
    await tester.pumpAndSettle();
    expect(surface('gradient'), decoration);
    expect(surface('course'), courseDecoration);
    expect(tester.takeException(), isNull);
  });

  testWidgets('去掉玻璃卡片描边后，封面贴合卡片边缘且保留显式内边距', (tester) async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    await theme.setFrostedGlass(true);
    const cover = Key('cover');
    const surface = Key('surface');
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: theme,
      child: MaterialApp(
          home: Scaffold(
              body: AppCardSurface(
        key: surface,
        width: 200,
        height: 120,
        padding: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Colors.white, width: 2),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const ColoredBox(key: cover, color: Colors.blue),
      ))),
    ));
    await tester.pumpAndSettle();
    final outer = tester.getRect(find.byKey(surface));
    expect(tester.getRect(find.byKey(cover)),
        Rect.fromLTWH(outer.left, outer.top, 200, 108));
    await theme.setFrostedGlass(false);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(cover)),
        Rect.fromLTWH(outer.left + 2, outer.top + 2, 196, 104));
  });

  for (final dark in [false, true]) {
    testWidgets('四种卡片材质像素一致，透明度只应用一次，无白边 dark=$dark', (tester) async {
      final theme = ThemeProvider(loadOnStart: false);
      addTearDown(theme.dispose);
      await theme.setBackgroundImage('morenbeijing.jpeg');
      await theme.setFrostedGlass(true);
      await theme.setComponentOpacity(.7);
      final capture = GlobalKey();
      final color = dark ? AppColors.surfaceSecondaryDark : Colors.white;
      var taps = 0;
      Widget content() => InkWell(
            onTap: () => taps++,
            child: const SizedBox(width: 200, height: 80),
          );
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: theme,
        child: MaterialApp(
          theme: dark ? ThemeData.dark() : ThemeData.light(),
          home: Scaffold(
            body: RepaintBoundary(
              key: capture,
              child: SizedBox(
                width: 320,
                height: 400,
                child: CustomPaint(
                  painter: _Stripes(),
                  child: Padding(
                    // 边缘距背景边界超过模糊核半径，避免背景边界色渗入采样。
                    padding: const EdgeInsets.symmetric(
                        horizontal: 60, vertical: 10),
                    child: Column(children: [
                      AppCardSurface(
                        width: 200,
                        height: 80,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: const SizedBox(width: 196, height: 76),
                      ),
                      const SizedBox(height: 10),
                      AppCard(
                        margin: EdgeInsets.zero,
                        color: color,
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.all(Radius.circular(16)),
                          side: BorderSide(color: Colors.white, width: 2),
                        ),
                        child: content(),
                      ),
                      const SizedBox(height: 10),
                      AppCardMaterial(
                        color: color,
                        borderRadius: BorderRadius.circular(16),
                        child: content(),
                      ),
                      const SizedBox(height: 10),
                      GlassContainer(
                        backgroundColor: color,
                        borderRadius: 16,
                        onTap: () => taps++,
                        child: const SizedBox(width: 200, height: 80),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      Future<void> checkPixels(double alpha, {bool blurred = true}) async {
        final bytes = (await tester.runAsync(() async {
          final boundary = capture.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes =
              await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          image.dispose();
          return bytes;
        }))!;
        for (var row = 0; row < 4; row++) {
          // 卡片中心的两条相邻黑白条纹都必须被模糊；材质不能重复叠底。
          for (final x in [148, 152]) {
            final offset = ((50 + row * 90) * 320 + x) * 4;
            var background = blurred ? 127.5 : ((x ~/ 4).isEven ? 255.0 : 0.0);
            if (!blurred && row == 3) {
              // GlassContainer 的普通样式保留原有 15% 阴影，阴影也会透过底面。
              background =
                  background * .85 + (dark ? 0 : Colors.grey.r * 255) * .15;
            }
            expect(bytes.getUint8(offset),
                closeTo(color.r * 255 * alpha + background * (1 - alpha), 3),
                reason: 'row=$row x=$x alpha=$alpha blurred=$blurred');
          }
          if (!blurred) continue; // 普通卡片恢复调用者的装饰描边。
          // 直边中部也不能绘制额外的白色描边。
          final edge = ((50 + row * 90) * 320 + 61) * 4;
          expect(bytes.getUint8(edge),
              closeTo(color.r * 255 * alpha + 127.5 * (1 - alpha), 3));
        }
      }

      expect(find.byType(BackdropFilter), findsNWidgets(4));
      await checkPixels(.7);
      for (final y in [140.0, 230.0, 320.0]) {
        await tester.tapAt(Offset(160, y));
      }
      expect(taps, 3);
      await tester.pumpAndSettle();
      await theme.setComponentOpacity(.4);
      await tester.pumpAndSettle();
      await checkPixels(.4);
      await theme.setFrostedGlass(false);
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      await checkPixels(.4, blurred: false);
      await theme.setComponentOpacity(.65);
      await tester.pumpAndSettle();
      await checkPixels(.65, blurred: false);
      await theme.setFrostedGlass(true);
      await tester.pumpAndSettle();
      await checkPixels(.65);
      await theme.setCleanBackgroundMode();
      await tester.pumpAndSettle();
      await checkPixels(1);
      await theme.setFrostedGlass(false);
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byType(Card), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
