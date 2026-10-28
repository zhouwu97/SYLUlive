import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/settings/appearance_settings_screen.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/app_scroll_behavior.dart';
import 'package:shenliyuan/widgets/global_background_wrapper.dart';
import 'package:shenliyuan/widgets/home_service_drawer.dart';
import 'package:shenliyuan/widgets/settings/settings_section.dart';
import 'package:shenliyuan/widgets/settings/campus_segmented_control.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

Widget _drawer(VoidCallback onGrades) => HomeServiceDrawer(
      checkedIn: false,
      streakDays: 0,
      checkInLoading: false,
      showCheckInDot: false,
      announcements: const [],
      unreadAnnouncements: const [],
      onCheckIn: () {},
      onOpenToolbox: () {},
      onOpenAnnouncements: () {},
      onOpenCompetitions: () {},
      onOpenGrades: onGrades,
      onOpenExamSchedule: () {},
      onOpenFeedback: () {},
      onOpenWaterSectionDirectory: () {},
    );

Widget _scroller(bool lazy) {
  final children = List.generate(
      18,
      (i) => AppCardSurface(
            key: ValueKey('card-$i'),
            height: 120,
            width: double.infinity,
            margin: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: Text('条目 $i'),
          ));
  return GlobalBackgroundWrapper(
      child: Scaffold(
    backgroundColor: Colors.transparent,
    body: lazy
        ? ListView(children: children)
        : SingleChildScrollView(child: Column(children: children)),
  ));
}

Future<List<int>> _pixels(
    WidgetTester tester, GlobalKey capture, Offset sample, String name) async {
  return (await tester.runAsync(() async {
    final boundary =
        capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    try {
      final bytes = (await image.toByteData())!;
      final offset = (sample.dy.round() * image.width + sample.dx.round()) * 4;
      final dir = Platform.environment['BACKGROUND_QA_DIR'];
      if (dir != null) {
        await Directory(dir).create(recursive: true);
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('$dir/$name.png').writeAsBytes(png.buffer.asUint8List());
      }
      return List.generate(4, (i) => bytes.getUint8(offset + i));
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final dark in [false, true]) {
    for (final layout in ['portrait', 'landscape', 'drawer']) {
      for (final fill in [false, true]) {
        testWidgets('背景 dark=$dark $layout fill=$fill 单张绘制，无重复补边图',
            (tester) async {
          await setGoldenViewport(
              tester,
              layout == 'landscape'
                  ? GoldenViewports.tabletLandscape1024x768
                  : GoldenViewports.phone390x844);
          final theme = ThemeProvider(loadOnStart: false);
          addTearDown(theme.dispose);
          await theme.setBackgroundImage('morenbeijing.jpeg', fillScreen: fill);
          await theme.setLandscapeBackgroundImage('morenbeijing.jpeg',
              fillScreen: fill);
          final capture = GlobalKey();
          await tester.pumpWidget(ChangeNotifierProvider.value(
            value: theme,
            child: RepaintBoundary(
                key: capture,
                child: GoldenTestApp(
                  themeMode: dark ? ThemeMode.dark : ThemeMode.light,
                  home: layout == 'drawer'
                      ? const Scaffold(
                          body: Align(
                              alignment: Alignment.topLeft,
                              child: SizedBox(
                                  width: 312,
                                  height: double.infinity,
                                  child: CustomBackgroundLayer())))
                      : const GlobalBackgroundWrapper(child: SizedBox.shrink()),
                )),
          ));
          await tester.pumpAndSettle();
          final image = tester.widget<Image>(find.byType(Image));
          expect(image.fit, BoxFit.cover);
          expect(
              (image.image as AspectPreservingResizeImage).fit, BoxFit.cover);
          await tester.runAsync(
              () => precacheImage(image.image, capture.currentContext!));
          await tester.pumpAndSettle();
          final pixel = await _pixels(tester, capture, const Offset(2, 2),
              'background-$dark-$layout-$fill');
          if (!fill) {
            final base =
                dark ? kCleanWarmBackgroundDark : kCleanWarmBackgroundLight;
            final expected = Color.alphaBlend(
                    dark
                        ? Colors.black.withValues(alpha: .35)
                        : Colors.white.withValues(alpha: .25),
                    base)
                .toARGB32();
            final rgb = [
              (expected >> 16) & 255,
              (expected >> 8) & 255,
              expected & 255
            ];
            expect(pixel.take(3).toList(), isNot(rgb),
                reason: '旧非铺满配置的边角也要由壁纸覆盖，不应留出页面底色');
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  for (final profile in ['light', 'dark', 'large-text']) {
    testWidgets('界面设置 $profile 模式选择器只有一层材质，预览遮罩一致', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone390x844);
      final theme = ThemeProvider(loadOnStart: false);
      addTearDown(theme.dispose);
      await theme.setBackgroundImage('morenbeijing.jpeg', fillScreen: true);
      await theme.setFrostedGlass(true);
      await theme.setComponentOpacity(.7);
      final capture = GlobalKey();
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: theme,
        child: RepaintBoundary(
          key: capture,
          child: GoldenTestApp(
            themeMode: profile == 'dark' ? ThemeMode.dark : ThemeMode.light,
            textScaler: profile == 'large-text'
                ? GoldenTextProfile.large.scaler
                : TextScaler.noScaling,
            home: const AppearanceSettingsScreen(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      for (final image in tester.widgetList<Image>(find.byType(Image))) {
        await tester.runAsync(
            () => precacheImage(image.image, capture.currentContext!));
      }
      await tester.pumpAndSettle();
      final selector = find.byType(CampusSegmentedControl<AppBackgroundMode>);
      expect(find.ancestor(of: selector, matching: find.byType(AppCardSurface)),
          findsNothing);
      final surface =
          find.descendant(of: selector, matching: find.byType(AppCardSurface));
      expect(surface, findsOneWidget);
      expect(tester.getSize(surface).height, 48);
      final mask = profile == 'dark'
          ? Colors.black.withValues(alpha: .35)
          : Colors.white.withValues(alpha: .25);
      final preview = find.ancestor(
          of: find.text('实时预览'), matching: find.byType(AnimatedContainer));
      expect(
          find.descendant(
              of: preview,
              matching: find.byWidgetPredicate(
                  (w) => w is ColoredBox && w.color == mask)),
          findsOneWidget);
      await _pixels(
          tester, capture, const Offset(20, 20), 'appearance-$profile');
      await tester.tap(find.text('简洁模式'));
      await tester.pumpAndSettle();
      expect(theme.isCleanBackgroundMode, isTrue);
      expect(theme.backgroundImage, 'morenbeijing.jpeg');
      await tester.tap(find.text('自定义背景'));
      await tester.pumpAndSettle();
      expect(theme.shouldShowCustomBackground, isTrue);
      expect(theme.componentOpacity, .7);
      expect(tester.takeException(), isNull);
    });
  }

  for (final profile in ['light', 'dark', 'large-text']) {
    for (final kind in ['drawer', 'list', 'single']) {
      testWidgets('$kind $profile 有效滚动及边缘持续拖动保持毛玻璃', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone390x844);
        final theme = ThemeProvider(loadOnStart: false);
        addTearDown(theme.dispose);
        await theme.setBackgroundImage('morenbeijing.jpeg', fillScreen: true);
        await theme.setFrostedGlass(true);
        await theme.setComponentOpacity(.7);
        final capture = GlobalKey();
        var gradeTaps = 0;
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: theme,
          child: RepaintBoundary(
            key: capture,
            child: GoldenTestApp(
              themeMode: profile == 'dark' ? ThemeMode.dark : ThemeMode.light,
              textScaler: profile == 'large-text'
                  ? GoldenTextProfile.large.scaler
                  : TextScaler.noScaling,
              home: Builder(builder: (context) {
                final glass = context.watch<ThemeProvider>().frostedGlass;
                // 与生产 MaterialApp 相同的应用级滚动行为，覆盖实际侧栏及两类列表。
                return ScrollConfiguration(
                    behavior: AppScrollBehavior(frostedGlass: glass),
                    child: kind == 'drawer'
                        ? Scaffold(body: _drawer(() => gradeTaps++))
                        : _scroller(kind == 'list'));
              }),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        final wallpaper = tester.widget<Image>(find.byType(Image).first).image;
        await tester
            .runAsync(() => precacheImage(wallpaper, capture.currentContext!));
        await tester.pumpAndSettle();
        expect(find.byType(StretchingOverscrollIndicator), findsNothing);
        final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
        expect(scroll.position.maxScrollExtent, greaterThan(100));

        // 先通过真正的手势改变 offset，避免把未越过触摸阈值的 MOVE 当作滚动验收。
        final gesture = await tester.startGesture(const Offset(280, 600));
        await gesture.moveBy(const Offset(0, -24));
        await tester.pump();
        await gesture.moveBy(const Offset(0, -80));
        await tester.pump(const Duration(milliseconds: 100));
        expect(scroll.position.pixels, greaterThan(20));
        await gesture.up();
        await tester.pumpAndSettle();
        scroll.position.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        final target = kind == 'drawer'
            ? find
                .ancestor(
                    of: find.text('成绩查询'),
                    matching: find.byType(AppCardSurface))
                .first
            : find.byKey(const ValueKey('card-17'));
        final rect = tester.getRect(target);
        final sample = Offset(rect.right - 42, rect.bottom - 32);
        final before =
            await _pixels(tester, capture, sample, '$kind-$profile-idle');
        final offset = scroll.position.pixels;
        final edge =
            await tester.startGesture(Offset(rect.right - 50, rect.center.dy));
        await edge.moveBy(const Offset(0, -24));
        await tester.pump();
        await edge.moveBy(const Offset(0, -140));
        await tester.pump(const Duration(milliseconds: 100));
        expect(scroll.position.pixels, offset);
        expect(await _pixels(tester, capture, sample, '$kind-$profile-held'),
            before);
        await edge.up();
        await tester.pumpAndSettle();
        expect(
            await _pixels(tester, capture, sample, '$kind-$profile-released'),
            before);

        if (kind == 'drawer') {
          expect(tester.getSize(find.byType(CustomBackgroundLayer)).width, 390);
          expect(find.byType(AppCardDivider), findsNWidgets(4));
          for (final divider in find.byType(AppCardDivider).evaluate()) {
            expect(
                find.descendant(
                    of: find.byWidget(divider.widget),
                    matching: find.byType(DecoratedBox)),
                findsNothing);
          }
          await tester.tap(find.text('成绩查询'));
          expect(gradeTaps, 1);
        }
        await theme.setFrostedGlass(false);
        await tester.pumpAndSettle();
        expect(find.byType(StretchingOverscrollIndicator), findsOneWidget);
        expect(find.byType(BackdropFilter), findsNothing);
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(TargetPlatform.android));
    }
  }

  testWidgets('菜单和设置装饰分隔线开关前后保持行高，关闭恢复线条', (tester) async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: theme,
      child: const MaterialApp(
          home: Scaffold(
              body: SettingsSection(children: [
        SizedBox(key: ValueKey('first'), width: double.infinity, height: 60),
        SizedBox(key: ValueKey('second'), width: double.infinity, height: 60),
      ]))),
    ));
    final divider = find.byType(AppCardDivider);
    double rowGap() =>
        tester.getTopLeft(find.byKey(const ValueKey('second'))).dy -
        tester.getBottomLeft(find.byKey(const ValueKey('first'))).dy;
    expect(rowGap(), 1);
    expect(find.descendant(of: divider, matching: find.byType(DecoratedBox)),
        findsOneWidget);
    await theme.setFrostedGlass(true);
    await tester.pumpAndSettle();
    expect(find.descendant(of: divider, matching: find.byType(DecoratedBox)),
        findsNothing);
    expect(rowGap(), 1);
    await theme.setFrostedGlass(false);
    await tester.pumpAndSettle();
    expect(find.descendant(of: divider, matching: find.byType(DecoratedBox)),
        findsOneWidget);
    expect(rowGap(), 1);
  });
}
