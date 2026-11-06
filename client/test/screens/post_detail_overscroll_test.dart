import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/theme/app_radius.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/post_reply_composer.dart';

import '../helpers/content_surface_fixtures.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';
import '../helpers/mock_public_image_http.dart';

Future<Color> _pixelAndCapture(
    WidgetTester tester, GlobalKey key, Offset point, String name) async {
  return (await tester.runAsync(() async {
    final render =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 1);
    try {
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final offset = (point.dy.floor() * image.width + point.dx.floor()) * 4;
      final color = Color.fromARGB(
          rgba!.getUint8(offset + 3),
          rgba.getUint8(offset),
          rgba.getUint8(offset + 1),
          rgba.getUint8(offset + 2));
      final directory = Platform.environment['POST_OVERSCROLL_EVIDENCE'];
      if (directory != null) {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(directory).create(recursive: true);
        await File('$directory/$name.png')
            .writeAsBytes(png!.buffer.asUint8List());
      }
      return color;
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() async {
    AppPreferencesStore.setMockInitialValues({});
    // 用真实解码的亮色图片区分正文图片、评论底面和壁纸。
    await installMockPublicImageHttp(
        imageBytes: base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAE0lEQVR4nGP4obDvPz7MMDIUAABlG7VB6XNHvwAAAABJRU5ErkJggg=='));
  });
  tearDown(uninstallMockPublicImageHttp);

  for (final dark in [false, true]) {
    for (final long in [false, true]) {
      for (final image in [false, true]) {
        final label = '${dark ? 'dark' : 'light'} long=$long image=$image';
        testWidgets('评论底面 $label 实际拖动和过滚保持衔接与材质', (tester) async {
          await setGoldenViewport(tester, GoldenViewports.phone390x844);
          final theme = ThemeProvider(loadOnStart: false);
          addTearDown(theme.dispose);
          await theme.setBackgroundImage('morenbeijing.jpeg');
          final dio = surfaceFixtureDio();
          dio.interceptors.insert(0, InterceptorsWrapper(onRequest: (o, h) {
            if (o.path != '/posts/300') return h.next(o);
            h.resolve(Response(requestOptions: o, statusCode: 200, data: {
              ...surfacePost(),
              if (long) 'content': List.filled(35, '长正文与短评论保持独立材质。').join('\n'),
              if (image)
                'images': [
                  {
                    'id': 1,
                    'post_id': 300,
                    'file_id': 1,
                    'file': {
                      'id': 1,
                      'path': 'https://fixture.invalid/uploads/overscroll.png',
                      'width': 800,
                      'height': 600,
                    }
                  }
                ],
            }));
          }));
          final boundary = GlobalKey();
          await tester.pumpWidget(ChangeNotifierProvider.value(
            value: theme,
            child: GoldenTestApp(
              themeMode: dark ? ThemeMode.dark : ThemeMode.light,
              textScaler:
                  dark ? const TextScaler.linear(1.3) : TextScaler.noScaling,
              home: RepaintBoundary(
                  key: boundary,
                  child: ScrollConfiguration(
                    behavior: const ScrollBehavior().copyWith(
                        physics: const BouncingScrollPhysics(
                            parent: AlwaysScrollableScrollPhysics())),
                    child: surfaceFixtureScene('post', dio),
                  )),
            ),
          ));
          await tester.pumpAndSettle();
          if (image) {
            bool decoded() => tester
                .widgetList<RawImage>(find.byType(RawImage))
                .any((widget) => widget.image?.width == 8);
            await driveMockPublicImageLoads(tester, until: decoded);
            expect(decoded(), isTrue, reason: '带图场景必须经过真实图片解码');
          }
          final wallpaper =
              tester.widget<Image>(find.byType(Image).first).image;
          await tester.runAsync(
              () => precacheImage(wallpaper, boundary.currentContext!));
          await tester.pumpAndSettle();
          final scroll = find.byKey(const ValueKey('post-detail-scroll-view'));
          final position = tester
              .state<ScrollableState>(find
                  .descendant(of: scroll, matching: find.byType(Scrollable))
                  .first)
              .position;
          final surface = find
              .ancestor(
                  of: find.text('还没有评论，来说点什么吧'),
                  matching: find.byType(AppCardSurface))
              .first;
          final composer = find.byType(PostReplyComposer);
          for (final state in [(false, 1.0), (true, .58), (false, .58)]) {
            final (glass, opacity) = state;
            await theme.setComponentOpacity(opacity);
            await theme.setFrostedGlass(glass);
            await tester.pumpAndSettle();
            position.jumpTo(position.maxScrollExtent);
            await tester.pumpAndSettle();
            final material = tester.widget<AppCardSurface>(surface);
            expect((material.decoration! as BoxDecoration).borderRadius,
                BorderRadius.circular(AppRadius.lg));
            expect(tester.getRect(surface).bottom,
                greaterThanOrEqualTo(tester.getRect(composer).top - 1),
                reason: '评论底面必须覆盖到输入栏，16px 留白应在材质内');
            final gesture = await tester
                .startGesture(Offset(24, tester.getRect(composer).top - 8));
            await gesture.moveBy(const Offset(0, -24));
            await tester.pump(const Duration(milliseconds: 40));
            await gesture.moveBy(const Offset(0, -160));
            await tester.pump(const Duration(milliseconds: 80));
            expect(position.pixels, greaterThan(position.maxScrollExtent),
                reason: '必须在手指保持的真实过滚状态验证');
            final edge = tester.getRect(composer).top;
            expect(
                tester.getRect(surface).bottom, greaterThanOrEqualTo(edge - 1),
                reason: '底部过滚不能把评论底面从输入栏拉开');
            final color = await _pixelAndCapture(
                tester,
                boundary,
                Offset(195, edge - 3),
                '$label-glass=$glass-alpha=$opacity-trailing');
            if (opacity == 1) {
              final expected = dark ? const Color(0xFF131720) : Colors.white;
              expect(color, expected, reason: '实色评论区接缝不能露出正文图片或壁纸');
            }
            await gesture.up();
            await tester.pumpAndSettle();
            if (!long) {
              position.jumpTo(position.minScrollExtent);
              await tester.pumpAndSettle();
              final leading = await tester
                  .startGesture(Offset(24, tester.getRect(composer).top - 8));
              await leading.moveBy(const Offset(0, 24));
              await tester.pump(const Duration(milliseconds: 40));
              await leading.moveBy(const Offset(0, 140));
              await tester.pump(const Duration(milliseconds: 80));
              expect(position.pixels, lessThan(position.minScrollExtent));
              expect(tester.getRect(surface).bottom,
                  greaterThanOrEqualTo(tester.getRect(composer).top - 1));
              await _pixelAndCapture(
                  tester,
                  boundary,
                  Offset(195, tester.getRect(composer).top - 3),
                  '$label-glass=$glass-alpha=$opacity-leading');
              await leading.up();
              await tester.pumpAndSettle();
            }
            expect(tester.takeException(), isNull);
          }
          await tester.pumpWidget(const SizedBox.shrink());
          if (image) await flushMockPublicImageTimers(tester);
        });
      }
    }
  }
}
