import '../helpers/active_backdrop_filters.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/app_bootstrap.dart';
import 'package:shenliyuan/models/campus_article.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/platform/contracts/external_navigator.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/theme/app_colors.dart';
import 'package:shenliyuan/theme/app_radius.dart';
import 'package:shenliyuan/theme/app_spacing.dart';
import 'package:shenliyuan/screens/campus_article_detail_screen.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/campus/campus_article_html.dart';

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
      final directory = Platform.environment['ARTICLE_CARD_QA_DIR'];
      if (directory != null && name != null) {
        await Directory(directory).create(recursive: true);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('$directory/$name.png')
            .writeAsBytes(bytes.buffer.asUint8List());
      }
      return (pixels: (await image.toByteData())!, width: image.width);
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

class _ExternalRecorder implements ExternalNavigator {
  final opened = <Uri>[];

  @override
  Future<bool> open(Uri uri) async {
    opened.add(uri);
    return true;
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final profile in [
    'primary',
    'wide-phone',
    'dark',
    'large-text',
    'stress'
  ]) {
    final dark = profile == 'dark';
    for (final kind in [
      'html',
      'text',
      'empty',
      'attachment',
      'unsafe-attachment'
    ]) {
      testWidgets('文章阅读卡片 $kind $profile 支持圆角、开关和滚动', (tester) async {
        final hasAttachment = kind.endsWith('attachment');
        final external = _ExternalRecorder();
        ExternalNavigator.register(external);
        addTearDown(() =>
            ExternalNavigator.register(const UnsupportedExternalNavigator()));
        await setGoldenViewport(
            tester,
            profile == 'wide-phone'
                ? GoldenViewports.phone390x844
                : GoldenViewports.phone360x800);
        final theme = ThemeProvider(loadOnStart: false);
        addTearDown(theme.dispose);
        await theme.setBackgroundImage('morenbeijing.jpeg');
        await theme.setFrostedGlass(true);
        final interceptor = InterceptorsWrapper(onRequest: (options, handler) {
          handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: {
            'item': {
              'id': 1,
              'title': '测试校园文章',
              'source_url': 'https://jwc.sylu.edu.cn/info/1/1.htm',
              'content_html': kind == 'html' ? '<p>${'校园正文内容。' * 60}</p>' : '',
              'content_text': kind == 'text' ? '校园正文内容。' * 60 : '',
              'attachments': hasAttachment
                  ? [
                      {
                        'name': '通知.pdf',
                        'extension': 'pdf',
                        'url': kind == 'attachment'
                            ? 'https://jwc.sylu.edu.cn/a.pdf'
                            : 'https://example.com/a.pdf'
                      }
                    ]
                  : [],
            },
          }));
        });
        getSharedDio().interceptors.insert(0, interceptor);
        addTearDown(() => getSharedDio().interceptors.remove(interceptor));
        final capture = GlobalKey();
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: theme,
          child: RepaintBoundary(
              key: capture,
              child: GoldenTestApp(
                themeMode: dark ? ThemeMode.dark : ThemeMode.light,
                textScaler: TextScaler.linear(profile == 'stress'
                    ? 1.5
                    : profile == 'large-text'
                        ? 1.3
                        : 1),
                home: const CampusArticleDetailScreen(
                  summary: CampusArticleSummary(id: 1, title: '测试校园文章'),
                ),
              )),
        ));
        await tester.pumpAndSettle();
        final wallpaper = tester.widget<Image>(find.byType(Image).first).image;
        await tester
            .runAsync(() => precacheImage(wallpaper, capture.currentContext!));
        await tester.pumpAndSettle();
        final surface =
            find.byKey(const ValueKey('campus-article-reading-surface'));
        expect(surface, findsOneWidget);
        final material = tester.widget<AppCardSurface>(surface);
        expect((material.decoration! as BoxDecoration).borderRadius,
            BorderRadius.circular(AppRadius.lg));
        final cardRect = tester.getRect(surface);
        final contentRect = tester.getRect(find.byWidget(material.child!));
        expect(cardRect.left, AppSpacing.lg);
        expect(contentRect.left - cardRect.left, AppSpacing.lg);
        expect(cardRect.right - contentRect.right, AppSpacing.lg);
        expect(contentRect.top - cardRect.top, AppSpacing.lg);
        expect(cardRect.bottom - contentRect.bottom, AppSpacing.lg);
        expect(
            find.ancestor(
                of: find.text('文章详情'), matching: find.byType(AppCardSurface)),
            findsNothing);
        expect(find.descendant(of: surface, matching: find.text('测试校园文章')),
            findsOneWidget);
        expect(find.descendant(of: surface, matching: activeBackdropFilters()),
            findsOneWidget);
        expect(
            find.descendant(of: surface, matching: find.byType(AppCardSurface)),
            findsNothing);
        if (kind == 'html') {
          expect(
              find.descendant(
                  of: surface, matching: find.byType(CampusArticleHtmlView)),
              findsOneWidget);
        } else if (kind == 'text') {
          expect(
              find.descendant(
                  of: surface, matching: find.byType(SelectableText)),
              findsOneWidget);
        } else {
          expect(
              find.descendant(
                  of: surface,
                  matching: find.byIcon(Icons.info_outline_rounded)),
              findsOneWidget);
        }
        final list = tester.widget<ListView>(find.byType(ListView));
        expect(
            (list.childrenDelegate as SliverChildListDelegate)
                .addRepaintBoundaries,
            isFalse);
        await _frame(tester, capture, '$kind-$profile-glass');
        if (kind == 'empty') {
          await theme.setFrostedGlass(false);
          await theme.setComponentOpacity(0);
          await tester.pumpAndSettle();
          final background = await _frame(tester, capture, null);
          await theme.setComponentOpacity(1);
          await tester.pumpAndSettle();
          final solid = await _frame(tester, capture, '$kind-$profile-solid');
          for (final corner in [
            cardRect.topLeft + const Offset(1, 1),
            cardRect.topRight + const Offset(-1, 1),
            cardRect.bottomLeft + const Offset(1, -1),
            cardRect.bottomRight + const Offset(-1, -1),
          ]) {
            expect(_pixel(solid, corner), _pixel(background, corner),
                reason: '四个角应实际透出壁纸，不能只设置未生效的圆角');
          }
          expect(
              _pixel(solid, Offset(cardRect.center.dx, cardRect.top + 4)),
              dark
                  ? AppColors.surfaceSecondaryDark
                  : AppColors.surfaceSecondaryLight);
          expect(tester.getRect(surface), cardRect);
        }
        if (kind == 'html' || kind == 'text') {
          await tester.drag(find.byType(ListView), const Offset(0, -400));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await theme.setFrostedGlass(false);
        await tester.pumpAndSettle();
        expect(surface, findsOneWidget, reason: '关闭毛玻璃后仍需阅读底面承载标题、正文和附件');
        expect(activeBackdropFilters(), findsNothing);
        expect(find.descendant(of: surface, matching: find.text('测试校园文章')),
            findsOneWidget);
        if (hasAttachment) {
          expect(find.descendant(of: surface, matching: find.text('通知.pdf')),
              findsOneWidget);
          expect(
              find.descendant(
                  of: surface, matching: find.text('学校附件需要输入验证码，请在浏览器中完成验证。')),
              findsOneWidget);
        }
        await _frame(tester, capture, '$kind-$profile-solid');
        if (hasAttachment) {
          await tester.ensureVisible(find.text('前往浏览器下载'));
          await tester.tap(find.text('前往浏览器下载'));
          await tester.pumpAndSettle();
          expect(
              external.opened,
              kind == 'attachment'
                  ? [Uri.parse('https://jwc.sylu.edu.cn/a.pdf')]
                  : isEmpty);
          if (kind == 'unsafe-attachment') {
            expect(find.text('附件地址无效'), findsWidgets);
          }
          await tester.ensureVisible(find.text('查看学校原文'));
          await tester.tap(find.text('查看学校原文'));
          await tester.pumpAndSettle();
          expect(external.opened.last,
              Uri.parse('https://jwc.sylu.edu.cn/info/1/1.htm'));
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final glass in [false, true]) {
    testWidgets('加载失败后重试仍保留阅读底面 glass=$glass', (tester) async {
      final theme = ThemeProvider(loadOnStart: false);
      addTearDown(theme.dispose);
      await theme.setBackgroundImage('morenbeijing.jpeg');
      await theme.setFrostedGlass(glass);
      final first = Completer<void>();
      var attempts = 0;
      final interceptor =
          InterceptorsWrapper(onRequest: (options, handler) async {
        attempts++;
        if (attempts == 1) {
          await first.future;
          handler.reject(DioException(
              requestOptions: options, type: DioExceptionType.connectionError));
        } else {
          handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: {
            'item': {'id': 1, 'title': '恢复后的文章', 'content_text': '恢复正文'},
          }));
        }
      });
      getSharedDio().interceptors.insert(0, interceptor);
      addTearDown(() => getSharedDio().interceptors.remove(interceptor));
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: theme,
        child: const GoldenTestApp(
            home: CampusArticleDetailScreen(
                summary: CampusArticleSummary(id: 1))),
      ));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(ListView), findsOneWidget);
      first.complete();
      await tester.pumpAndSettle();
      expect(find.text('点击重试'), findsOneWidget);
      await tester.tap(find.text('点击重试'));
      await tester.pumpAndSettle();
      expect(find.text('恢复后的文章'), findsOneWidget);
      expect(find.byKey(const ValueKey('campus-article-reading-surface')),
          findsOneWidget);
      expect(attempts, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
