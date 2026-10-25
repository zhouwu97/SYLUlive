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

      Future<void> checkPixels(double alpha) async {
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
            expect(bytes.getUint8(offset),
                closeTo(color.r * 255 * alpha + 127.5 * (1 - alpha), 3));
          }
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
