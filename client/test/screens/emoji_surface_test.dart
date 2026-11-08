import '../helpers/active_backdrop_filters.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/theme/app_spacing.dart';
import '../helpers/emoji_surface_fixtures.dart';
import 'package:shenliyuan/features/emoji/presentation/emoji_ui.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  for (final profile in ['light', 'dark-large', 'clean', 'dark-clean']) {
    for (final scene in ['official', 'management', 'panel']) {
      testWidgets('表情 $scene $profile 玻璃底面覆盖内容与工具栏', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone390x844);
        final appearance = ThemeProvider(loadOnStart: false);
        addTearDown(appearance.dispose);
        final clean = profile.contains('clean');
        await appearance.setBackgroundImage('morenbeijing.jpeg');
        await appearance.setComponentOpacity(.7);
        await appearance.setFrostedGlass(true);
        if (clean) {
          await appearance.setCleanBackgroundMode();
        }
        final capture = GlobalKey();
        await tester.pumpWidget(ChangeNotifierProvider.value(
            value: appearance,
            child: RepaintBoundary(
                key: capture,
                child: GoldenTestApp(
                    themeMode: profile.startsWith('dark')
                        ? ThemeMode.dark
                        : ThemeMode.light,
                    textScaler: profile.startsWith('dark')
                        ? const TextScaler.linear(1.3)
                        : TextScaler.noScaling,
                    home: emojiSurfaceScene(scene)))));
        await tester.pumpAndSettle();
        for (final im
            in tester.widgetList<Image>(find.byType(Image)).toList()) {
          await tester
              .runAsync(() => precacheImage(im.image, capture.currentContext!));
        }
        await tester.pumpAndSettle();
        Future<void> captureFrame(String state) async {
          final dir = Platform.environment['BACKGROUND_QA_DIR'];
          if (dir == null) return;
          await tester.runAsync(() async {
            final image = await (capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
            final png =
                (await image.toByteData(format: ui.ImageByteFormat.png))!;
            await Directory(dir).create(recursive: true);
            await File('$dir/$scene-$profile-$state.png')
                .writeAsBytes(png.buffer.asUint8List());
            image.dispose();
          });
        }

        expect(activeBackdropFilters(), clean ? findsNothing : findsWidgets,
            reason: '简洁模式保留内容底面并暂停模糊，自定义背景启用玻璃');
        expect(find.byType(AppCardMaterial), findsWidgets);
        if (scene != 'panel') {
          final card = find.byType(EmojiContentCard).first;
          expect(tester.getSize(card).height, lessThan(650),
              reason: '内容卡片不能铺满整个空白页面');
        }
        await captureFrame('initial');
        if (scene == 'management') {
          final tabSurface = find.ancestor(
              of: find.text('收藏'), matching: find.byType(AppContentSurface));
          final tabsRect = tester.getRect(tabSurface);
          for (final label in ['收藏', '我的表情包', '收藏']) {
            await tester.tap(find.text(label));
            await tester.pumpAndSettle();
            final header = find.text(label == '收藏' ? '我的收藏' : '已安装');
            final content = find.ancestor(
                of: header, matching: find.byType(EmojiContentCard));
            expect(tester.getRect(tabSurface), tabsRect,
                reason: '切换标签不能移动标题栏或把它并入内容卡片');
            expect(tester.getRect(content).top - tabsRect.bottom, AppSpacing.md,
                reason: '两个标签始终保留独立卡片之间的相同留白');
            expect(
                find.ancestor(
                    of: tabSurface, matching: find.byType(EmojiContentCard)),
                findsNothing);
          }
          expect(find.text('暂无收藏的表情'), findsOneWidget);
        } else if (scene == 'panel') {
          await tester.tap(find.byKey(const ValueKey('emoji-tab-favorite')));
          await tester.pumpAndSettle();
          expect(find.text('暂无收藏的表情'), findsOneWidget);
          // 内容和工具栏共用一个底面，不能再叠加白色工具栏。
          final surface = find.byKey(const ValueKey('emoji-panel-surface'));
          expect(
              find.descendant(of: surface, matching: activeBackdropFilters()),
              clean ? findsNothing : findsOneWidget);
        } else {
          expect(find.text('本地官方表情'), findsOneWidget);
        }
        await captureFrame('favorites');
        expect(tester.takeException(), isNull);
        await appearance.setFrostedGlass(false);
        await tester.pumpAndSettle();
        expect(activeBackdropFilters(), findsNothing);
        for (final material in tester
            .widgetList<AppCardMaterial>(find.byType(AppCardMaterial))) {
          expect(material.color?.a, 1, reason: '玻璃关闭后，浅色、深色与简约模式都必须有实色卡片底面');
        }
        await captureFrame('solid');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
