import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/screens/canteen_detail_screen.dart';

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

ResponseBody _json(String body, int status) {
  return ResponseBody.fromString(body, status, headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  });
}

String _detailJson({
  List<Map<String, String>> ratings = const [],
  int ratingCount = 0,
}) {
  final ratingsJson = ratings
      .map((r) =>
          '{"id":${r['id'] ?? 1},"user_id":2,"user_name":"同学A",'
          '"comment":"${r['comment'] ?? '好吃'}","star":${r['star'] ?? 5},'
          '"images":"[]","helpful_count":1,"unhelpful_count":0,'
          '"created_at":"2026-07-22"}')
      .join(',');
  return '''
  {
    "canteen": {"id":1,"name":"我家有面","image":"/uploads/a.jpg","verified":true,"created_by":1},
    "ratings": [$ratingsJson],
    "rating_count": $ratingCount,
    "average_star": 5.0,
    "my_rating": null
  }
  ''';
}

Widget _buildApp(Dio dio) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
      ChangeNotifierProvider(create: (_) => AuthProvider(dio)),
    ],
    child: const MaterialApp(
      home: CanteenDetailScreen(
        canteenId: 1,
        canteenName: '我家有面',
        dishCount: 2,
        dishPhotoCount: 5,
      ),
    ),
  );
}

Dio _dioWith(String detailBody) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'));
  dio.httpClientAdapter = FakeAdapter((options) async {
    if (options.path == '/canteens/1' && options.method == 'GET') {
      return _json(detailBody, 200);
    }
    return _json('{"error":"not found"}', 404);
  });
  return dio;
}

void main() {
  testWidgets('首次进入显示骨架而非中央 spinner', (tester) async {
    final dio = _dioWith(_detailJson());
    await tester.pumpWidget(_buildApp(dio));
    await tester.pump();

    // 请求未返回时：页面骨架（无全屏 CircularProgressIndicator）
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('我家有面'), findsOneWidget);
  });

  testWidgets('切换筛选不出现全屏 loading，Hero/信息区保持', (tester) async {
    final dio = _dioWith(_detailJson(ratingCount: 2));
    await tester.pumpWidget(_buildApp(dio));
    await tester.pumpAndSettle();

    // 点击「有图」筛选
    await tester.tap(find.text('有图'));
    await tester.pump();

    // 页面不消失：店名仍在（无 full-screen loading）
    expect(find.text('我家有面'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // 不出现全屏 loading Scaffold
    expect(find.text('加载失败'), findsNothing);

    await tester.pumpAndSettle();
  });

  testWidgets('快速切换筛选时陈旧响应不覆盖新状态', (tester) async {
    // 可控响应：记录每个请求的 filter，允许乱序完成
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    final pending = <({String filter, Completer<ResponseBody> completer})>[];
    dio.httpClientAdapter = FakeAdapter((options) async {
      if (options.path == '/canteens/1' && options.method == 'GET') {
        final filter =
            options.queryParameters['review_filter']?.toString() ?? 'all';
        final completer = Completer<ResponseBody>();
        pending.add((filter: filter, completer: completer));
        return completer.future;
      }
      return _json('{"error":"not found"}', 404);
    });

    await tester.pumpWidget(_buildApp(dio));

    // 等待首个请求发出
    for (var i = 0; i < 50 && pending.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(pending, isNotEmpty, reason: '首个请求未发出');

    // 首个请求（all）先返回
    pending[0].completer.complete(_json(_detailJson(ratingCount: 3), 200));
    await tester.pumpAndSettle();
    expect(find.text('用户评价'), findsOneWidget);

    // 点击「有图」→ 请求 A（with_image，慢）
    await tester.ensureVisible(find.text('有图'));
    await tester.pump();
    await tester.tap(find.text('有图'), warnIfMissed: true);
    for (var i = 0; i < 50 &&
        !pending.any((r) => r.filter == 'with_image'); i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    // 再点「高分」→ 请求 B（high，快）
    // 注意：A 未返回期间评价区顶部有 indeterminate 进度条动画，
    // 不能用 pumpAndSettle，用离散 pump。
    await tester.ensureVisible(find.text('高分'));
    await tester.pump();
    await tester.tap(find.text('高分'), warnIfMissed: true);
    for (var i = 0; i < 50 && !pending.any((r) => r.filter == 'high'); i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    // ignore: avoid_print
    print('pending filters: ${pending.map((r) => r.filter).toList()}');
    expect(pending.any((r) => r.filter == 'high'), isTrue,
        reason: '高分请求未发出');
    final requestB = pending.firstWhere((r) => r.filter == 'high');
    final requestA = pending.firstWhere((r) => r.filter == 'with_image');

    // 请求 B 先返回（空）→ 数据落地后进度条消失，可安全 settle
    requestB.completer.complete(_json(_detailJson(ratingCount: 0), 200));
    await tester.pumpAndSettle();
    expect(find.text('暂无高分评价'), findsOneWidget);

    // 请求 A（with_image，带数据）晚到 → 必须被 generation 丢弃
    requestA.completer
        .complete(_json(_detailJson(ratingCount: 1, ratings: [
          {'id': '9', 'comment': '带图评价', 'star': '5'},
        ]), 200));
    await tester.pumpAndSettle();

    // 仍停留在「高分」空态，未被陈旧 with_image 响应覆盖
    expect(find.text('暂无高分评价'), findsOneWidget);
    expect(find.text('带图评价'), findsNothing);
  });

  testWidgets('菜品为空时图鉴区显示上传 CTA', (tester) async {
    final dio = _dioWith(_detailJson());
    dio.httpClientAdapter = FakeAdapter((options) async {
      if (options.path == '/canteens/1' && options.method == 'GET') {
        return _json(_detailJson(), 200);
      }
      if (options.path == '/canteens/1/dishes' && options.method == 'GET') {
        return _json('[]', 200);
      }
      return _json('{"error":"not found"}', 404);
    });

    await tester.pumpWidget(_buildApp(dio));
    await tester.pumpAndSettle();

    // 空态不再 SizedBox.shrink：显示上传 CTA
    expect(find.text('还没有同学上传菜品实拍'), findsOneWidget);
    expect(find.text('上传菜品实拍'), findsOneWidget);
  });

  testWidgets('320px 宽度渲染无溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final dio = _dioWith(_detailJson(ratingCount: 2));
    await tester.pumpWidget(_buildApp(dio));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('评价项不使用独立卡片而是 divider 分隔', (tester) async {
    final dio = _dioWith(
      _detailJson(
        ratings: [
          {'id': '1', 'comment': '小面好吃', 'star': '5'},
          {'id': '2', 'comment': '夯爆了', 'star': '4'},
        ],
        ratingCount: 2,
      ),
    );
    await tester.pumpWidget(_buildApp(dio));
    await tester.pumpAndSettle();

    expect(find.text('小面好吃'), findsOneWidget);
    expect(find.text('夯爆了'), findsOneWidget);
    // 星级简化为单星数字，不出现五个重复星
    expect(find.byIcon(Icons.star_rounded), findsWidgets);
    // 无独立卡片容器
    expect(find.byType(Card), findsNothing);
  });
}
