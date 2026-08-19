import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_discovery_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/screens/canteen_ranking_screen.dart';

const _rankingsBody =
    '{"items":['
    '{"rank":1,"id":1,"name":"一食堂二楼","image":"/uploads/a.jpg","average_star":4.6,'
    '"rating_count":5,"ranking_score":86.0,"confidence":"low","dish_count":12,"dish_photo_count":26,'
    '"summary_tags":[{"key":"taste_good","name":"味道不错","count":8}]},'
    '{"rank":2,"id":2,"name":"二食堂","image":"","average_star":5.0,"rating_count":1,'
    '"ranking_score":83.0,"confidence":"low","dish_count":0,"dish_photo_count":0,"summary_tags":[]}'
    '],"meta":{"sort":"composite","algorithm":"bayesian","prior_weight":5,"total":2}}';

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
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
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

    expect(find.text('食堂综合排行'), findsOneWidget);
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
}
