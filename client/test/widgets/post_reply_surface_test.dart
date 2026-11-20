import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/reply.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/theme/app_colors.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/global_background_wrapper.dart';
import 'package:shenliyuan/widgets/post_reply/post_reply_list.dart';

import '../helpers/content_surface_fixtures.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

const _backdrop = Color(0xFF245C90);
const _previewText = '楼中楼透明度验收';
const _output = String.fromEnvironment('REPLY_SURFACE_QA_OUTPUT');

Map<String, dynamic> _reply({bool child = false}) => {
      'id': child ? 22 : 21,
      'post_id': 300,
      'author_id': child ? 3 : 2,
      'content': child ? _previewText : '根评论',
      'created_at': '2026-11-11T08:00:00Z',
      'author': {'id': child ? 3 : 2, 'nickname': child ? '回复者' : '发起者'},
      if (child) 'parent_reply_id': 21,
      if (child) 'reply_to_name': '发起者',
      if (!child) 'child_reply_count': 1,
    };

Dio _dio() {
  final dio = surfaceFixtureDio();
  dio.interceptors.insert(0, InterceptorsWrapper(onRequest: (o, h) {
    if (o.path.contains('/replies')) {
      h.resolve(Response(requestOptions: o, statusCode: 200, data: {
        'replies': [
          if (!o.path.endsWith('/children')) _reply(),
          _reply(child: true),
        ],
        'total': 2,
        'next_cursor': '',
      }));
    } else if (o.path == '/posts/300') {
      h.resolve(Response(requestOptions: o, statusCode: 200, data: {
        ...surfacePost(),
        'reply_count': 2,
      }));
    } else {
      h.next(o);
    }
  }));
  return dio;
}

Future<List<Color>> _pixels(WidgetTester tester, GlobalKey capture,
    List<Offset> points, String name) async {
  return (await tester.runAsync(() async {
    final image = await (capture.currentContext!.findRenderObject()!
            as RenderRepaintBoundary)
        .toImage(pixelRatio: 1);
    try {
      if (_output.isNotEmpty) {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(_output).create(recursive: true);
        await File('$_output/$name.png')
            .writeAsBytes(png!.buffer.asUint8List());
      }
      final rgba =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      return points.map((point) {
        final offset = (point.dy.floor() * image.width + point.dx.floor()) * 4;
        return Color.fromARGB(rgba.getUint8(offset + 3), rgba.getUint8(offset),
            rgba.getUint8(offset + 1), rgba.getUint8(offset + 2));
      }).toList();
    } finally {
      image.dispose();
    }
  }))!;
}

void _expectColor(Color actual, Color expected) {
  expect(actual.r, closeTo(expected.r, 2 / 255));
  expect(actual.g, closeTo(expected.g, 2 / 255));
  expect(actual.b, closeTo(expected.b, 2 / 255));
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final dark in [false, true]) {
    for (final detail in [false, true]) {
      final label = '${detail ? 'post' : 'shared'}-${dark ? 'dark' : 'light'}';
      testWidgets('楼中楼预览沿用父卡片透明度且没有实色白带 $label', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone360x800);
        final appearance = ThemeProvider(loadOnStart: false);
        addTearDown(appearance.dispose);
        await appearance.setBackgroundImage('morenbeijing.jpeg');
        final capture = GlobalKey();
        final surface = dark ? AppColors.surfaceSecondaryDark : Colors.white;
        await tester.pumpWidget(RepaintBoundary(
          key: capture,
          child: ChangeNotifierProvider.value(
            value: appearance,
            child: GoldenTestApp(
              themeMode: dark ? ThemeMode.dark : ThemeMode.light,
              home: ColoredBox(
                color: _backdrop,
                child: SharedPageBackground(
                  child: detail
                      ? surfaceFixtureScene('post', _dio())
                      : Scaffold(
                          backgroundColor: Colors.transparent,
                          body: AppCardSurface(
                            margin: const EdgeInsets.all(16),
                            padding: const EdgeInsets.all(16),
                            color: surface,
                            child: PostReplyList(
                              replies: [
                                Reply.fromJson(_reply()),
                                Reply.fromJson(_reply(child: true)),
                              ],
                              onReply: (_) {},
                            ),
                          ),
                        ),
                ),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        final preview = find.byWidgetPredicate((widget) =>
            widget is RichText &&
            widget.text.toPlainText().contains(_previewText));
        expect(preview, findsOneWidget);
        final layers = find
            .ancestor(of: preview, matching: find.byType(Container))
            .evaluate()
            .take(2)
            .map((element) => tester.getRect(find.byWidget(element.widget)))
            .toList();
        final points = layers
            .map((rect) => Offset(rect.right - 4, rect.center.dy))
            .toList();
        for (final opacity in [.2, .5, .75, .95]) {
          await appearance.setComponentOpacityLevel(opacity);
          await tester.pumpAndSettle();
          final expected =
              Color.alphaBlend(
                  surface.withValues(alpha: .75 + .25 * opacity), _backdrop);
          for (final pixel
              in await _pixels(tester, capture, points, '$label-$opacity')) {
            _expectColor(pixel, expected);
          }
        }

        if (detail) {
          await tester.tap(preview);
          await tester.pumpAndSettle();
          final related = find.ancestor(
              of: find.textContaining('相关回复共'), matching: find.byType(Column));
          final rect = tester.getRect(related.first);
          // 分区留白应透出同一底面；旧版 8px 实色条会覆盖这四个采样行。
          final strip = await _pixels(
              tester,
              capture,
              [
                for (final dy in [1, 2, 5, 6, 10])
                  Offset(rect.left + 4, rect.top + dy),
              ],
              '$label-thread');
          for (final pixel in strip.take(4)) {
            _expectColor(pixel, strip.last);
          }
          await tester.tap(find.byTooltip('关闭回复'));
          await tester.pumpAndSettle();
        }

        await appearance.setFrostedGlass(true);
        await tester.pumpAndSettle();
        final expected =
            Color.alphaBlend(surface.withValues(alpha: .9875), _backdrop);
        for (final pixel
            in await _pixels(tester, capture, points, '$label-glass')) {
          _expectColor(pixel, expected);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
