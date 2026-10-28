import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bottom_nav_demo/main.dart';
import 'package:bottom_nav_demo/widgets/liquid_glass/liquid_glass_renderer.dart';
import 'package:bottom_nav_demo/widgets/liquid_glass/liquid_glass_runtime.dart';

void main() {
  testWidgets('live scene captures scroll and expanded lens without feedback', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await loadLiquidGlassProgram();
      final loader = FontLoader('NotoSansCJKsc')
        ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'));
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(key: key, child: const NavigationDemo()),
    );
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    expect(liquidGlassRuntimeStatus.value.tier, LiquidGlassTier.a);

    Future<void> snapshot(String name) async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        Directory('build/verification').createSync(recursive: true);
        File(
          'build/verification/$name.png',
        ).writeAsBytesSync(png!.buffer.asUint8List());
        image.dispose();
      });
    }

    await snapshot('flutter-light');
    await tester.tap(find.text('网格背景'));
    await tester.tap(find.text('清透材质'));
    await tester.pumpAndSettle();
    final selection = find.byKey(const ValueKey('bottom-nav-selection'));
    final idleHeight = tester.getSize(selection).height;
    final gesture = await tester.startGesture(tester.getCenter(selection));
    await tester.pump();
    for (var i = 0; i < 18; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.getSize(selection).height, greaterThan(idleHeight * 1.3));
    final dock = tester.getRect(
      find.byKey(const ValueKey('bottom-nav-floating-dock')),
    );
    final from = tester.getCenter(selection);
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset.lerp(from, dock.center, i / 10)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await snapshot('flutter-pressed');
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('切换深色模式'));
    await tester.pumpAndSettle();
    await snapshot('flutter-dark');
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -360));
    await tester.pumpAndSettle();
    await snapshot('flutter-scroll');
    expect(liquidGlassRuntimeStatus.value.tier, LiquidGlassTier.a);
    expect(tester.takeException(), isNull);
    // A static frame must not start a perpetual capture/render loop.
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
