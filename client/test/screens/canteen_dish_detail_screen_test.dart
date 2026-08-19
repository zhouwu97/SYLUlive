import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/screens/canteen_dish_detail_screen.dart';

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

Widget _buildApp({required String detailJson}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'));
  dio.httpClientAdapter = FakeAdapter((options) async {
    if (options.path == '/canteens/1/dishes/12') {
      return _json(detailJson, 200);
    }
    return _json('{"error":"not found"}', 404);
  });
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
      ChangeNotifierProvider(
        create: (_) => _FakeAuthProvider(),
      ),
    ],
    child: const MaterialApp(
      home: CanteenDishDetailScreen(
        canteenId: 1,
        dishId: 12,
        dishName: '锅包肉',
        canteenName: '一食堂二楼',
      ),
    ),
  );
}

class _FakeAuthProvider extends ChangeNotifier {}

void main() {
  testWidgets('3/3 显示实拍资料已完善且无上传按钮', (tester) async {
    await tester.pumpWidget(_buildApp(detailJson: '''
      {
        "dish": {"id":12,"name":"锅包肉","canteen_id":1},
        "photo_count": 3,
        "photos": [
          {"id":1,"image":"/uploads/a.jpg","created_at":"2026-08-13"},
          {"id":2,"image":"/uploads/b.jpg","created_at":"2026-08-13"},
          {"id":3,"image":"/uploads/c.jpg","created_at":"2026-08-13"}
        ]
      }
    '''));
    await tester.pumpAndSettle();

    expect(find.text('实拍图库 3 / 3'), findsOneWidget);
    expect(find.text('实拍资料已完善'), findsOneWidget);
    expect(find.text('上传菜品实拍'), findsNothing);
  });

  testWidgets('1/3 显示上传入口状态', (tester) async {
    await tester.pumpWidget(_buildApp(detailJson: '''
      {
        "dish": {"id":12,"name":"锅包肉","canteen_id":1},
        "photo_count": 1,
        "photos": [{"id":1,"image":"/uploads/a.jpg","created_at":"2026-08-13"}]
      }
    '''));
    await tester.pumpAndSettle();

    expect(find.text('实拍图库 1 / 3'), findsOneWidget);
    expect(find.text('上传菜品实拍'), findsOneWidget);
    expect(find.text('实拍资料已完善'), findsNothing);
  });

  testWidgets('无星级评分展示', (tester) async {
    await tester.pumpWidget(_buildApp(detailJson: '''
      {
        "dish": {"id":12,"name":"锅包肉","canteen_id":1},
        "photo_count": 2,
        "photos": [
          {"id":1,"image":"/uploads/a.jpg","created_at":"2026-08-13"},
          {"id":2,"image":"/uploads/b.jpg","created_at":"2026-08-13"}
        ]
      }
    '''));
    await tester.pumpAndSettle();

    // 不出现 "评分" 字样
    expect(find.textContaining('评分'), findsNothing);
    expect(find.byIcon(Icons.star_rounded), findsNothing);
  });
}
