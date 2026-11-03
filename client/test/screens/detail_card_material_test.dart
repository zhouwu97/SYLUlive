import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/theme/app_colors.dart';
import 'package:shenliyuan/theme/app_radius.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/poll/poll_post_card.dart';

import '../helpers/active_backdrop_filters.dart';
import '../helpers/content_surface_fixtures.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

Future<({ByteData pixels, int width})> _frame(
    WidgetTester tester, GlobalKey key, String? name) async {
  return (await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage();
    try {
      final pixels = (await image.toByteData())!;
      final directory = Platform.environment['DETAIL_CARD_QA_DIR'];
      if (directory != null && name != null) {
        await Directory(directory).create(recursive: true);
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('$directory/$name.png')
            .writeAsBytes(png.buffer.asUint8List());
      }
      return (pixels: pixels, width: image.width);
    } finally {
      image.dispose();
    }
  }))!;
}

Color _pixel(({ByteData pixels, int width}) frame, Offset point) {
  final offset = (point.dy.floor() * frame.width + point.dx.floor()) * 4;
  return Color.fromARGB(
      frame.pixels.getUint8(offset + 3),
      frame.pixels.getUint8(offset),
      frame.pixels.getUint8(offset + 1),
      frame.pixels.getUint8(offset + 2));
}

void _expectColor(Color actual, Color expected) {
  for (final channel in [
    (actual.r, expected.r),
    (actual.g, expected.g),
    (actual.b, expected.b),
    (actual.a, expected.a),
  ]) {
    expect(channel.$1, closeTo(channel.$2, 2 / 255));
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final profile in ['light', 'dark-large', 'clean']) {
    for (final scene in ['poll', 'post']) {
      testWidgets('$scene $profile 评论底色一致且真实绘制不越过圆角', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone390x844);
        final theme = ThemeProvider(loadOnStart: false);
        addTearDown(theme.dispose);
        await theme.setBackgroundImage('morenbeijing.jpeg');
        if (profile == 'clean') await theme.setCleanBackgroundMode();
        await theme.setComponentOpacity(0);
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
              home: surfaceFixtureScene(scene, surfaceFixtureDio()),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        for (final image in tester.widgetList<Image>(find.byType(Image))) {
          await tester.runAsync(
              () => precacheImage(image.image, capture.currentContext!));
        }
        await tester.pumpAndSettle();
        final scroll =
            tester.state<ScrollableState>(find.byType(Scrollable).first);
        scroll.position.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        final surface = scene == 'poll'
            ? find.byKey(const ValueKey('poll-comments-surface'))
            : find
                .ancestor(
                    of: find.text('还没有评论，来说点什么吧'),
                    matching: find.byType(AppCardSurface))
                .first;
        final rect = tester.getRect(surface);
        final corners = [
          rect.topLeft + const Offset(1, 1),
          rect.topRight + const Offset(-1, 1),
          rect.bottomLeft + const Offset(1, -1),
          rect.bottomRight + const Offset(-1, -1),
        ];
        final fill = Offset(rect.center.dx, rect.bottom - 4);
        final background = await _frame(tester, capture, null);
        final base = profile == 'dark-large'
            ? AppColors.surfaceSecondaryDark
            : AppColors.surfaceSecondaryLight;

        if (scene == 'poll') {
          final poll = tester.widget<AppCard>(find.descendant(
              of: find.byType(PollPostCard), matching: find.byType(AppCard)));
          expect((poll.shape! as RoundedRectangleBorder).borderRadius,
              BorderRadius.circular(AppRadius.lg));
          expect(poll.color, base);
        }
        await theme.setComponentOpacity(1);
        await tester.pumpAndSettle();
        final opaque = await _frame(tester, capture, '$scene-$profile-solid');
        _expectColor(_pixel(opaque, fill), base);
        for (final corner in corners) {
          _expectColor(_pixel(opaque, corner), _pixel(background, corner));
        }
        expect(tester.getRect(surface), rect, reason: '底色变化不能移动评论、改变内容宽度或滚动位置');

        await theme.setComponentOpacity(.6);
        await tester.pumpAndSettle();
        final translucent = await _frame(tester, capture, null);
        _expectColor(
            _pixel(translucent, fill),
            profile == 'clean'
                ? base
                : Color.alphaBlend(
                    base.withValues(alpha: .6), _pixel(background, fill)));
        await theme.setFrostedGlass(true);
        await tester.pumpAndSettle();
        expect(find.descendant(of: surface, matching: activeBackdropFilters()),
            profile == 'clean' ? findsNothing : findsOneWidget);
        expect(tester.getRect(surface), rect);
        final glass = await _frame(tester, capture, '$scene-$profile-glass');
        for (final corner in corners) {
          _expectColor(_pixel(glass, corner), _pixel(background, corner));
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
