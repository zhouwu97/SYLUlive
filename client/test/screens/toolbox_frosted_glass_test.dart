import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/toolbox_screen.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/glass_container.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

Widget _buildWrapper(ThemeProvider theme) {
  return ChangeNotifierProvider<ThemeProvider>.value(
    value: theme,
    child: const MaterialApp(home: ToolboxScreen()),
  );
}

Future<ThemeProvider> _createProvider() async {
  final theme = ThemeProvider(loadOnStart: false);
  await theme.loadThemeForTesting();
  return theme;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadTestFonts);

  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
  });

  testWidgets('毛玻璃关闭时 Toolbox 卡片内不包含 BackdropFilter', (tester) async {
    final theme = await _createProvider();
    expect(theme.frostedGlass, isFalse);

    await tester.pumpWidget(_buildWrapper(theme));
    await tester.pumpAndSettle();

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('二课分查询'), findsOneWidget);
    expect(find.text('更多工具'), findsOneWidget);
  });

  testWidgets('毛玻璃开启时 Toolbox 卡片包含 BackdropFilter', (tester) async {
    final theme = await _createProvider();
    await theme.setFrostedGlass(true);
    expect(theme.frostedGlass, isTrue);

    await tester.pumpWidget(_buildWrapper(theme));
    await tester.pumpAndSettle();

    expect(find.byType(BackdropFilter), findsWidgets);
    expect(find.text('二课分查询'), findsOneWidget);
    expect(find.text('更多工具'), findsOneWidget);
  });

  for (final profile in ['light', 'dark', 'large-text', 'wide-phone']) {
    testWidgets('工具箱 $profile 下滑及停止保持材质，无白边且跟随透明度设置', (tester) async {
      await setGoldenViewport(
          tester,
          profile == 'wide-phone'
              ? GoldenViewports.phone390x844
              : GoldenViewports.phone360x800);
      final theme = await _createProvider();
      await theme.setBackgroundImage('morenbeijing.jpeg', fillScreen: true);
      await theme.setFrostedGlass(true);
      await theme.setComponentOpacity(0.7);
      final capture = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
        key: capture,
        child: ChangeNotifierProvider.value(
          value: theme,
          child: GoldenTestApp(
            themeMode: profile == 'dark' ? ThemeMode.dark : ThemeMode.light,
            textScaler: profile == 'large-text'
                ? GoldenTextProfile.large.scaler
                : TextScaler.noScaling,
            home: const ToolboxScreen(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      // 网格不独立滚动，也不应产生可单独缓存的嵌套 viewport。
      expect(find.byType(Scrollable), findsOneWidget);
      expect(find.byType(StretchingOverscrollIndicator), findsNothing);
      // 等待真实壁纸解码，避免把首帧占位底色误判为滚动导致的材质变化。
      final wallpaper = tester.widget<Image>(find.byType(Image).first).image;
      await tester
          .runAsync(() => precacheImage(wallpaper, capture.currentContext!));
      await tester.pumpAndSettle();
      final card = find
          .ancestor(
              of: find.text('考试日程'), matching: find.byType(GlassContainer))
          .first;
      final rect = tester.getRect(card);
      final sample = Offset(rect.right - 24, rect.center.dy);
      Future<List<int>> pixels(String state) async {
        return (await tester.runAsync(() async {
          final boundary = capture.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
          final image = await boundary.toImage();
          try {
            final data = (await image.toByteData())!;
            final offset =
                (sample.dy.round() * image.width + sample.dx.round()) * 4;
            final dir = Platform.environment['BACKGROUND_QA_DIR'];
            if (dir != null) {
              await Directory(dir).create(recursive: true);
              final png =
                  (await image.toByteData(format: ui.ImageByteFormat.png))!;
              await File('$dir/toolbox-$profile-$state.png')
                  .writeAsBytes(png.buffer.asUint8List());
            }
            return List.generate(4, (i) => data.getUint8(offset + i));
          } finally {
            image.dispose();
          }
        }))!;
      }

      final before = await pixels('idle');
      final gesture = await tester.startGesture(rect.center);
      // 超过触摸阈值并持续拉动，覆盖 Android 的边缘拉伸合成层。
      await gesture.moveBy(const Offset(0, 24));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 120));
      await tester.pump(const Duration(milliseconds: 100));
      final during = await pixels('drag');
      for (var i = 0; i < 4; i++) {
        expect(during[i], closeTo(before[i], 3), reason: '滚动不能切换材质或透明度');
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(await pixels('settled'), before);
      final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
      if (scroll.position.maxScrollExtent > 30) {
        final scrollGesture =
            await tester.startGesture(Offset(10, rect.center.dy));
        await scrollGesture.moveBy(const Offset(0, -20));
        await tester.pump();
        await scrollGesture.moveBy(const Offset(0, -8));
        await tester.pump(const Duration(milliseconds: 100));
        expect(scroll.position.pixels, greaterThan(0));
        final scrolling = await pixels('scrolling');
        for (var i = 0; i < 4; i++) {
          expect(scrolling[i], closeTo(before[i], 3));
        }
        await scrollGesture.up();
        await tester.pumpAndSettle();
        scroll.position.jumpTo(0);
        await tester.pumpAndSettle();
        expect(await pixels('returned'), before);
      }
      final material =
          find.descendant(of: card, matching: find.byType(AppCardSurface));
      final fill = find
          .descendant(
              of: material,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Container &&
                    widget.decoration is BoxDecoration &&
                    (widget.decoration! as BoxDecoration).color != null,
              ))
          .first;
      BoxDecoration decoration() =>
          tester.widget<Container>(fill).decoration! as BoxDecoration;
      expect(decoration().color!.a, closeTo(0.7, 0.01));
      expect(decoration().border, isNull);
      await theme.setComponentOpacity(0.4);
      await tester.pumpAndSettle();
      expect(decoration().color!.a, closeTo(0.4, 0.01));
      await theme.setFrostedGlass(false);
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      expect(decoration().color!.a, 1);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}
