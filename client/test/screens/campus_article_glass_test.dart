import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/app_bootstrap.dart';
import 'package:shenliyuan/models/campus_article.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/campus_article_detail_screen.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/campus/campus_article_html.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final dark in [false, true]) {
    for (final kind in ['html', 'text', 'empty', 'attachment']) {
      testWidgets('文章阅读背景 $kind dark=$dark 支持开关和滚动', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone390x844);
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
              'content_html': kind == 'html' ? '<p>${'校园正文内容。' * 60}</p>' : '',
              'content_text': kind == 'text' ? '校园正文内容。' * 60 : '',
              'attachments': kind == 'attachment'
                  ? [
                      {'name': '通知.pdf', 'url': 'https://example.com/a.pdf'}
                    ]
                  : [],
            },
          }));
        });
        getSharedDio().interceptors.insert(0, interceptor);
        addTearDown(() => getSharedDio().interceptors.remove(interceptor));
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: theme,
          child: GoldenTestApp(
            themeMode: dark ? ThemeMode.dark : ThemeMode.light,
            textScaler: const TextScaler.linear(1.3),
            home: const CampusArticleDetailScreen(
              summary: CampusArticleSummary(id: 1, title: '测试校园文章'),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        final surface =
            find.byKey(const ValueKey('campus-article-reading-surface'));
        expect(surface, findsOneWidget);
        expect(find.descendant(of: surface, matching: find.text('测试校园文章')),
            findsOneWidget);
        expect(
            find.descendant(of: surface, matching: find.byType(BackdropFilter)),
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
        if (kind == 'html' || kind == 'text') {
          await tester.drag(find.byType(ListView), const Offset(0, -400));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await theme.setFrostedGlass(false);
        await tester.pumpAndSettle();
        expect(surface, findsNothing);
        expect(find.byType(BackdropFilter), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('加载失败后重试成功仍使用文章毛玻璃', (tester) async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setFrostedGlass(true);
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
        handler
            .resolve(Response(requestOptions: options, statusCode: 200, data: {
          'item': {'id': 1, 'title': '恢复后的文章', 'content_text': '恢复正文'},
        }));
      }
    });
    getSharedDio().interceptors.insert(0, interceptor);
    addTearDown(() => getSharedDio().interceptors.remove(interceptor));
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: theme,
      child: const GoldenTestApp(
          home:
              CampusArticleDetailScreen(summary: CampusArticleSummary(id: 1))),
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
