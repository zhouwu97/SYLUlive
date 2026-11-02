import '../helpers/active_backdrop_filters.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/app_bootstrap.dart';
import 'package:shenliyuan/legal/legal_documents.dart';
import 'package:shenliyuan/models/campus_article.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/campus_article_detail_screen.dart';
import 'package:shenliyuan/screens/legal_documents_screen.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/campus/campus_theme.dart';
import 'package:shenliyuan/widgets/global_background_wrapper.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

Future<List<Color>> _pixels(
    WidgetTester tester, GlobalKey key, Rect surface, String name) async {
  return (await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    try {
      final bytes = (await image.toByteData())!;
      Color sample(int x, int y) {
        final offset = (y * image.width + x) * 4;
        return Color.fromARGB(
            bytes.getUint8(offset + 3),
            bytes.getUint8(offset),
            bytes.getUint8(offset + 1),
            bytes.getUint8(offset + 2));
      }

      final result = [
        sample((surface.left + 6).round(), (surface.top + 80).round()),
        sample(2, 300),
      ];
      final directory = Platform.environment['BACKGROUND_QA_DIR'];
      if (directory != null) {
        await Directory(directory).create(recursive: true);
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('$directory/$name.png')
            .writeAsBytes(png.buffer.asUint8List());
      }
      return result;
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final scene in ['article', 'legal']) {
    for (final profile in ['light', 'dark', 'large-text']) {
      testWidgets('$scene $profile 关闭毛玻璃时文字有实色底面，外围仍是壁纸', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone390x844);
        final theme = ThemeProvider(loadOnStart: false);
        addTearDown(theme.dispose);
        await theme.setBackgroundImage('morenbeijing.jpeg');
        await theme.setFrostedGlass(false);
        final interceptor = InterceptorsWrapper(onRequest: (o, h) {
          h.resolve(Response(requestOptions: o, statusCode: 200, data: {
            'item': {
              'id': 1,
              'title': '校园阅读背景验收',
              'content_text': '正文应在连续底面上保持清晰，可滚动和复制。' * 80,
              'source_url': 'https://jwc.sylu.edu.cn/info/1/1.htm',
            },
          }));
        });
        getSharedDio().interceptors.insert(0, interceptor);
        addTearDown(() => getSharedDio().interceptors.remove(interceptor));
        final capture = GlobalKey();
        // 使用实际最长文档验证滚动，短协议在普通字号下可完整显示。
        final document = LegalDocuments.all
            .reduce((a, b) => a.body.length >= b.body.length ? a : b);
        final title = scene == 'article' ? '校园阅读背景验收' : document.title;
        final surface = find.byKey(ValueKey(scene == 'article'
            ? 'campus-article-reading-surface'
            : 'legal-document-reading-surface'));
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: theme,
          child: GoldenTestApp(
            themeMode: profile == 'dark' ? ThemeMode.dark : ThemeMode.light,
            textScaler: profile == 'large-text'
                ? GoldenTextProfile.large.scaler
                : TextScaler.noScaling,
            home: RepaintBoundary(
              key: capture,
              child: scene == 'article'
                  ? const CampusArticleDetailScreen(
                      summary: CampusArticleSummary(id: 1))
                  : LegalDocumentsScreen(initialDocumentId: document.id),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        final wallpaper = tester.widget<Image>(find.byType(Image)).image;
        await tester
            .runAsync(() => precacheImage(wallpaper, capture.currentContext!));
        await tester.pumpAndSettle();
        expect(surface, findsOneWidget);
        expect(find.descendant(of: surface, matching: find.text(title)),
            findsOneWidget);
        expect(activeBackdropFilters(), findsNothing);
        final colors = await _pixels(tester, capture, tester.getRect(surface),
            '$scene-$profile-reading-off');
        expect(colors.first,
            profile == 'dark' ? CampusTheme.darkCard : CampusTheme.card);
        expect(colors.last, isNot(colors.first), reason: '阅读底面不应覆盖页面外围的自定义壁纸');

        await tester.drag(find.byType(ListView), const Offset(0, -300));
        await tester.pumpAndSettle();
        final position = tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position;
        final offset = position.pixels;
        expect(offset, greaterThan(0));
        await theme.setFrostedGlass(true);
        await tester.pumpAndSettle();
        expect(surface, findsOneWidget);
        expect(activeBackdropFilters(), findsOneWidget);
        expect(position.pixels, offset);
        await theme.setFrostedGlass(false);
        await theme.setCleanBackgroundMode();
        await tester.pumpAndSettle();
        expect(surface, findsOneWidget);
        expect(position.pixels, offset);
        expect(find.byType(Image), findsNothing);
        await theme.trySetCustomBackgroundMode();
        await tester.pumpAndSettle();
        expect(position.pixels, offset);
        expect(find.byType(CustomBackgroundLayer), findsOneWidget);
        expect(activeBackdropFilters(), findsNothing);
        expect(find.byType(scene == 'article' ? SelectableText : SelectionArea),
            findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('协议目录有底面，进入正文并返回仍可继续选择其他协议', (tester) async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: theme,
      child: const GoldenTestApp(home: LegalDocumentsScreen()),
    ));
    await tester.pumpAndSettle();
    final document = LegalDocuments.all.first;
    final entry = find.widgetWithText(ListTile, document.title);
    expect(find.ancestor(of: entry, matching: find.byType(AppCardSurface)),
        findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.text(document.body.trim()), findsOneWidget);
    expect(find.byType(SelectionArea), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNWidgets(LegalDocuments.all.length));
    expect(tester.takeException(), isNull);
  });
}
