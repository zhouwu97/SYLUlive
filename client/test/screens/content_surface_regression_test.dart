import '../helpers/active_backdrop_filters.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/browsing_history_item.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/repositories/browsing_history_repository.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/app_scroll_behavior.dart';

import '../helpers/content_surface_fixtures.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final output = Platform.environment['BACKGROUND_QA_DIR'];
  if (output == null) return;
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage();
    try {
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await Directory(output).create(recursive: true);
      await File('$output/$name.png').writeAsBytes(bytes.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  for (final profile in ['light', 'dark-large', 'clean']) {
    for (final scene in [
      'likes',
      'history',
      'social',
      'flags',
      'permissions',
      'poll',
      'post'
    ]) {
      testWidgets('$scene $profile 内容有底面，保留玻璃开关和交互', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone390x844);
        final theme = ThemeProvider(loadOnStart: false);
        addTearDown(theme.dispose);
        await theme.setBackgroundImage('morenbeijing.jpeg');
        await theme.setComponentOpacity(.7);
        await theme.setFrostedGlass(true);
        if (profile == 'clean') await theme.setCleanBackgroundMode();
        await BrowsingHistoryRepository().recordVisit(
            userId: '1',
            targetId: '300',
            type: BrowsingHistoryType.post,
            title: '校园里的新鲜事',
            author: '非常长的作者昵称用于验证时间与删除按钮不会被挤出屏幕');
        final capture = GlobalKey();
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: theme,
          child: RepaintBoundary(
              key: capture,
              child: GoldenTestApp(
                themeMode:
                    profile == 'dark-large' ? ThemeMode.dark : ThemeMode.light,
                textScaler: profile == 'dark-large'
                    ? const TextScaler.linear(1.3)
                    : TextScaler.noScaling,
                home: ScrollConfiguration(
                    behavior: const AppScrollBehavior(frostedGlass: true),
                    child: surfaceFixtureScene(scene, surfaceFixtureDio())),
              )),
        ));
        await tester.pumpAndSettle();
        for (final image
            in tester.widgetList<Image>(find.byType(Image)).toList()) {
          await tester.runAsync(
              () => precacheImage(image.image, capture.currentContext!));
        }
        await tester.pumpAndSettle();
        final text = switch (scene) {
          'likes' => find.text('同学1 赞了你的评论'),
          'history' => find.text('校园里的新鲜事'),
          'social' => find.text('测试同学'),
          'flags' => find.text('校园 AI 问答'),
          'permissions' => find.text('AI 主动刷新教务'),
          'poll' => find.text('评论内容应清晰可读，下方回复使用同一块底面。'),
          'post' => find.text('还没有评论，来说点什么吧'),
          _ => throw StateError(scene),
        };
        await tester.ensureVisible(text.first);
        await tester.pumpAndSettle();
        expect(
            find.ancestor(
                of: text.first,
                matching: find.byWidgetPredicate(
                    (w) => w is AppCardSurface || w is AppCardMaterial)),
            findsWidgets,
            reason: '文字不能直接叠在页面壁纸上');
        await _capture(tester, capture, '$scene-$profile');
        expect(tester.takeException(), isNull);
        if (scene == 'history') {
          await tester.tap(find.text('校园资讯'));
          await tester.pumpAndSettle();
          expect(find.text('暂无浏览记录'), findsOneWidget);
          await tester.tap(find.text('全部'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('清空记录'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(find.text('校园里的新鲜事'), findsOneWidget);
          if (profile == 'light') {
            await tester.drag(find.byType(Dismissible), const Offset(-350, 0));
          } else {
            await tester.tap(find.byTooltip('删除此条记录'));
          }
          await tester.pumpAndSettle();
          final empty = find.text('暂无浏览记录');
          expect(empty, findsOneWidget);
          expect(
              find.ancestor(of: empty, matching: find.byType(AppCardSurface)),
              findsOneWidget);
        } else if (scene == 'social') {
          await tester.tap(find.text('粉丝'));
          await tester.pumpAndSettle();
          expect(find.text('测试同学'), findsWidgets);
        } else if (scene == 'poll' || scene == 'post') {
          expect(find.byType(TextField), findsWidgets);
        }
        final surfaces = find.byType(AppCardSurface);
        final glassRects = surfaces
            .evaluate()
            .map((e) => tester.getRect(find.byWidget(e.widget)))
            .toList();
        await theme.setFrostedGlass(false);
        await tester.pumpAndSettle();
        expect(
            surfaces
                .evaluate()
                .map((e) => tester.getRect(find.byWidget(e.widget)))
                .toList(),
            glassRects,
            reason: '切换毛玻璃只能改变材质，不能改变卡片位置和尺寸');
        expect(activeBackdropFilters(), findsNothing);
        await _capture(tester, capture, '$scene-$profile-solid');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
