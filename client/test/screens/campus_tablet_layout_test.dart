import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/app_bootstrap.dart';
import 'package:shenliyuan/models/campus_article.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/screens/campus_article_detail_screen.dart';
import 'package:shenliyuan/screens/campus_screen.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  var failArticle = false;
  late Interceptor interceptor;
  setUp(() {
    failArticle = false;
    AppPreferencesStore.setMockInitialValues({});
    interceptor = InterceptorsWrapper(onRequest: (options, handler) {
      if (options.path == '/campus/articles/1') {
        if (failArticle) {
          handler.reject(DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              response: Response(requestOptions: options, statusCode: 400)));
        } else {
          handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: {
            'item': {
              'id': 1,
              'title': '校园文章',
              'content_text': '用于验证 Pad 阅读宽度的校园通知正文。' * 30
            }
          }));
        }
      } else {
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'items': [], 'item': null, 'has_more': false}));
      }
    });
    getSharedDio().interceptors.insert(0, interceptor);
  });
  tearDown(() {
    getSharedDio().interceptors.remove(interceptor);
  });

  testWidgets('Pad 校园聚合页、文章正文及错误重试均在内容宽度内', (tester) async {
    tester.view.devicePixelRatio = 1;
    await setGoldenViewport(tester, GoldenViewports.tabletLandscape1280x800);
    await tester.pumpWidget(const GoldenTestApp(
        themeMode: ThemeMode.dark,
        textScaler: TextScaler.linear(1.3),
        home: CampusScreen()));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(CustomScrollView)).width, 1000);
    expect(find.text('校园服务'), findsOneWidget);
    expect(tester.takeException(), isNull);
    failArticle = true;
    await tester.pumpWidget(const GoldenTestApp(
        themeMode: ThemeMode.dark,
        textScaler: TextScaler.linear(1.3),
        home: CampusArticleDetailScreen(
            summary: CampusArticleSummary(id: 1, title: '校园文章'))));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ListView)).width, 840);
    expect(find.text('点击重试'), findsOneWidget);
    failArticle = false;
    await tester.tap(find.text('点击重试'));
    await tester.pumpAndSettle();
    expect(find.textContaining('用于验证 Pad 阅读宽度'), findsOneWidget);
    await setGoldenViewport(tester, GoldenViewports.tabletPortrait834x1194);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ListView)).width, 834);
    expect(tester.takeException(), isNull);
  });
}
