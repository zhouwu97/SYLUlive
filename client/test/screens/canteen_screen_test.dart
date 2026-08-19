import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_discovery_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/screens/canteen_screen.dart';

const _homeBody =
    '{"hero":{"type":"recommended_store","canteen_id":1,"canteen_name":"一食堂二楼",'
    '"image":"/uploads/a.jpg","ranking_score":92.0,"average_star":4.8,"rating_count":86,'
    '"title":"今日推荐","reason":"同学们常常提到\\u201c味道不错\\u201d","tags":["味道不错"]},'
    '"ranking_entry":{"top":{"id":1,"name":"一食堂二楼","ranking_score":92.0},"total":2},'
    '"feed":['
    '{"id":"recent_photo:5","type":"recent_photo","canteen_id":2,"canteen_name":"二食堂",'
    '"dish_id":5,"dish_name":"红烧牛肉面","title":"同学最近实拍","images":["/uploads/p.jpg"]},'
    '{"id":"stable_choice:3","type":"stable_choice","canteen_id":3,"canteen_name":"三食堂面馆",'
    '"ranking_score":84.0,"average_star":4.5,"rating_count":12,"title":"想吃稳一点？",'
    '"reason":"评价样本较多，近期反馈比较稳定","tags":["分量足","出餐快"]}'
    ']}';

/// 构造一个返回食堂首页数据的 Dio Adapter。
Dio _buildDio() {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'));
  dio.httpClientAdapter = FakeAdapter((options) async {
    if (options.path == '/canteens/home' && options.method == 'GET') {
      return _json(_homeBody);
    }
    return ResponseBody.fromString('{"error":"not found"}', 404);
  });
  return dio;
}

ResponseBody _json(String body) => ResponseBody.fromString(
      body,
      200,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );

class FakeAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions options) _handler;
  FakeAdapter(this._handler);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    return _handler(options);
  }

  @override
  void close({bool force = false}) {}
}

Widget _buildApp([Dio? dio]) {
  final d = dio ?? _buildDio();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => CanteenProvider(d)),
      ChangeNotifierProvider(create: (_) => CanteenDiscoveryProvider(d)),
      ChangeNotifierProvider(create: (_) => AuthProvider(d)),
    ],
    child: const MaterialApp(home: CanteenScreen()),
  );
}

void main() {
  testWidgets('进入页面请求 /canteens/home（发现聚合），不请求旧整榜', (tester) async {
    final requests = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = FakeAdapter((options) async {
      requests.add('${options.method} ${options.path}');
      if (options.path == '/canteens/home' && options.method == 'GET') {
        return _json(_homeBody);
      }
      return ResponseBody.fromString('{"error":"not found"}', 404);
    });

    await tester.pumpWidget(_buildApp(dio));
    await tester.pumpAndSettle();

    expect(requests.where((r) => r == 'GET /canteens/home'), hasLength(1));
    // 旧整榜列表接口不应再被首页使用。
    expect(requests.where((r) => r == 'GET /canteens'), isEmpty);
    expect(find.text('校园食堂'), findsOneWidget);
  });

  testWidgets('首页展示 Hero 今日推荐与综合排行入口', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    expect(find.text('今日推荐'), findsOneWidget);
    expect(find.text('一食堂二楼'), findsWidgets); // Hero + 排行入口 Top1
    expect(find.text('综合排行'), findsOneWidget);
    // 首页不再以整榜数字排名渲染（不存在 01/02 榜单数字）。
    expect(find.text('01'), findsNothing);
  });

  testWidgets('推荐信息流渲染多类型 Card（实拍 + 稳妥选择）', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    expect(find.text('同学最近实拍'), findsOneWidget);
    expect(find.textContaining('红烧牛肉面'), findsOneWidget);

    // 第二张卡（稳妥选择）在折叠区外，向上滚动后断言。
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('想吃稳一点？'), findsOneWidget);
    expect(find.text('三食堂面馆'), findsOneWidget);
  });

  testWidgets('无 FAB', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('搜索过滤信息流', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '三食堂');
    await tester.pumpAndSettle();

    expect(find.text('三食堂面馆'), findsOneWidget);
    expect(find.text('红烧牛肉面'), findsNothing);
  });

  testWidgets('搜索无结果时提供提交这家店 CTA', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '不存在的食堂');
    await tester.pumpAndSettle();

    expect(find.textContaining('没有找到'), findsOneWidget);
    expect(find.text('提交这家店'), findsOneWidget);
  });
}
