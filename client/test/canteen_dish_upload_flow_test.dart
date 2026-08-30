import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/screens/canteen_detail_screen.dart';

/// 菜品实拍现在随食堂评价提交，详情页不能再把用户引向已退休的独立投稿接口。

class FakeAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions options) _handler;
  FakeAdapter(this._handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
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

const _detailJson = '''
{
  "canteen": {"id":1,"name":"我家有面","image":"/uploads/a.jpg","verified":true,"created_by":1},
  "ratings": [],
  "rating_count": 0,
  "average_star": 0.0,
  "my_rating": null
}
''';

void main() {
  testWidgets('贡献入口只打开当前评价流程，不再展示独立实拍投稿', (tester) async {
    final requests = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = FakeAdapter((options) async {
      requests.add('${options.method} ${options.path}');
      if (options.path == '/canteens/1' && options.method == 'GET') {
        return _json(_detailJson, 200);
      }
      if (options.path == '/canteens/1/dishes' && options.method == 'GET') {
        return _json('[]', 200);
      }
      return _json('{"error":"not found"}', 404);
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
          ChangeNotifierProvider(create: (_) => AuthProvider(dio)),
        ],
        child: const MaterialApp(
          home: CanteenDetailScreen(
            canteenId: 1,
            canteenName: '我家有面',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('贡献内容'));
    await tester.pumpAndSettle();

    expect(find.text('你想贡献什么？'), findsOneWidget);
    expect(find.text('写菜品评价'), findsOneWidget);
    expect(find.text('评价中可以关联菜品并上传实拍，帮助其他同学做决定'), findsOneWidget);
    expect(find.text('上传菜品实拍'), findsNothing);

    // 未登录时由当前评价入口统一处理鉴权，不得发起已退休的独立投稿请求。
    await tester.tap(find.text('写菜品评价'));
    await tester.pumpAndSettle();
    expect(find.text('请先登录后评价'), findsOneWidget);
    expect(
      requests.any((request) =>
          request.contains('/dish-photos') ||
          request.contains('/dish-submissions')),
      isFalse,
    );
  });
}
