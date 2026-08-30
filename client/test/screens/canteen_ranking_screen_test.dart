import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_discovery_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/screens/canteen_detail_screen.dart';
import 'package:shenliyuan/screens/canteen_ranking_screen.dart';
import 'package:shenliyuan/widgets/canteen/canteen_detail_skeleton.dart';
import 'package:shenliyuan/widgets/canteen/canteen_status_image.dart';

const _rankingsBody = '{"items":['
    '{"rank":1,"id":1,"name":"一食堂二楼","image":"/uploads/a.jpg","average_star":4.6,'
    '"rating_count":5,"ranking_score":86.0,"confidence":"low","dish_count":12,"dish_photo_count":26,'
    '"summary_tags":[{"key":"taste_good","name":"味道不错","count":8}]},'
    '{"rank":2,"id":2,"name":"二食堂","image":"","average_star":5.0,"rating_count":1,'
    '"ranking_score":83.0,"confidence":"low","dish_count":0,"dish_photo_count":0,"summary_tags":[]}'
    '],"meta":{"sort":"composite","algorithm":"bayesian","prior_weight":5,"total":2}}';

const _detailBody =
    '{"canteen":{"id":1,"name":"一食堂二楼","image":"/uploads/a.jpg",'
    '"verified":true,"created_by":1},"ratings":[],"rating_count":0,'
    '"average_star":0.0,"my_rating":null}';

class _FakeAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions) _handler;
  _FakeAdapter(this._handler);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    return _handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(String body) => ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType]
      },
    );

Widget _app(Dio dio) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
      ChangeNotifierProvider(create: (_) => CanteenDiscoveryProvider(dio)),
      ChangeNotifierProvider(create: (_) => AuthProvider(dio)),
    ],
    child: const MaterialApp(home: CanteenRankingScreen()),
  );
}

void main() {
  testWidgets('排行页加载并使用服务端 rank，不自行 index+1', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = _FakeAdapter((options) async {
      if (options.path == '/canteens/rankings') {
        return _json(_rankingsBody);
      }
      return ResponseBody.fromString('{"error":"not found"}', 404);
    });

    await tester.pumpWidget(_app(dio));
    await tester.pumpAndSettle();

    expect(find.text('商家排行'), findsOneWidget);
    // rank 由服务端返回
    expect(find.text('01'), findsOneWidget);
    expect(find.text('02'), findsOneWidget);
    expect(find.text('一食堂二楼'), findsOneWidget);
    // 综合分展示
    expect(find.text('综合分 86'), findsOneWidget);
    // 样本很少提示（rating_count=1）
    expect(find.text('样本很少'), findsOneWidget);
  });

  testWidgets('切排序触发新的 /rankings 请求', (tester) async {
    final sorts = <String?>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = _FakeAdapter((options) async {
      sorts.add(options.uri.queryParameters['sort']);
      if (options.path == '/canteens/rankings') {
        return _json(_rankingsBody);
      }
      return ResponseBody.fromString('{"error":"not found"}', 404);
    });

    await tester.pumpWidget(_app(dio));
    await tester.pumpAndSettle();

    // 首次加载 composite
    expect(sorts.contains('composite'), isTrue);

    await tester.tap(find.text('评分优先'));
    await tester.pumpAndSettle();

    expect(sorts.contains('rating'), isTrue);
  });

  testWidgets('点击排行项时详情 loading 立即保留入口封面 Hero', (tester) async {
    final detailPending = Completer<ResponseBody>();
    var detailRequested = false;
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = _FakeAdapter((options) async {
      if (options.path == '/canteens/rankings') {
        return _json(_rankingsBody);
      }
      if (options.path == '/canteens/1/detail' ||
          options.path == '/canteens/1') {
        detailRequested = true;
        return detailPending.future;
      }
      return ResponseBody.fromString('{"error":"not found"}', 404);
    });

    await tester.pumpWidget(_app(dio));
    await tester.pumpAndSettle();

    await tester.tap(find.text('一食堂二楼'));
    for (var i = 0; i < 50 && !detailRequested; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    // 等待路由 Hero flight 落地，确认目标页自身仍保留入口图片。
    await tester.pump(const Duration(milliseconds: 350));

    expect(detailRequested, isTrue);
    expect(find.byType(CanteenDetailSkeleton), findsOneWidget);
    final detailHeroFinder = find.descendant(
      of: find.byType(CanteenDetailScreen),
      matching: find.byWidgetPredicate(
        (widget) => widget is Hero && widget.tag == 'canteen-ranking-1',
      ),
    );
    expect(detailHeroFinder, findsOneWidget);
    final heroImage = tester.widget<CanteenStatusImage>(
      find.byWidgetPredicate(
        (widget) => widget is CanteenStatusImage && widget.variant == 'medium',
      ),
    );
    expect(heroImage.imageUrl, '/uploads/a.jpg');
    expect(heroImage.variant, 'medium');
    expect(heroImage.offline, isFalse);
    expect(
      find.descendant(
        of: find.byType(CanteenDetailSkeleton),
        matching: find.byType(Hero),
      ),
      findsNothing,
    );

    detailPending.complete(ResponseBody.fromString(_detailBody, 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType]
    }));
    await tester.pumpAndSettle();
  });
}
