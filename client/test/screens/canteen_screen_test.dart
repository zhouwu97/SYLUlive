import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/screens/canteen_screen.dart';

/// 构造一个返回固定食堂列表的 Dio Adapter。
Dio _buildDio() {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'));
  dio.httpClientAdapter = FakeAdapter((options) async {
    if (options.path == '/canteens' && options.method == 'GET') {
      return ResponseBody.fromString(
        '[{"id":1,"name":"一食堂二楼","image":"/uploads/a.jpg","verified":true,'
        '"created_by":1,"rating_count":86,"average_star":4.8,'
        '"dish_count":12,"dish_photo_count":26},'
        '{"id":2,"name":"二食堂","image":"","verified":true,"created_by":1,'
        '"rating_count":3,"average_star":5.0,"dish_count":0,"dish_photo_count":0}]',
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString('{"error":"not found"}', 404);
  });
  return dio;
}

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

Widget _buildApp() {
  final dio = _buildDio();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
      ChangeNotifierProvider(create: (_) => AuthProvider(dio)),
    ],
    child: const MaterialApp(home: CanteenScreen()),
  );
}

void main() {
  testWidgets('进入页面加载食堂且仅请求 /canteens', (tester) async {
    final requests = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = FakeAdapter((options) async {
      requests.add('${options.method} ${options.path}');
      if (options.path == '/canteens' && options.method == 'GET') {
        return ResponseBody.fromString(
          '[{"id":1,"name":"一食堂二楼","image":"/uploads/a.jpg","verified":true,'
          '"created_by":1,"rating_count":86,"average_star":4.8}]',
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      return ResponseBody.fromString('{"error":"not found"}', 404);
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
          ChangeNotifierProvider(create: (_) => AuthProvider(dio)),
        ],
        child: const MaterialApp(home: CanteenScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(requests.where((r) => r == 'GET /canteens'), hasLength(1));
    expect(requests.where((r) => r.contains('/teachers')), isEmpty);
    expect(requests.where((r) => r.contains('/majors')), isEmpty);
    expect(find.text('校园食堂'), findsOneWidget);
    expect(find.text('一食堂二楼'), findsOneWidget);
  });

  testWidgets('无 FAB，列表末尾提供提交食堂入口', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    // FAB 已删除
    expect(find.byType(FloatingActionButton), findsNothing);
    // 列表末尾的提交入口
    expect(find.textContaining('提交新的食堂'), findsOneWidget);
  });

  testWidgets('菜品统计在卡片中渲染', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    expect(find.text('12 道菜 · 26 张实拍'), findsOneWidget);
    expect(find.text('暂无同学实拍'), findsOneWidget);
  });

  testWidgets('排名使用排版数字且无 badge 容器', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    expect(find.text('01'), findsOneWidget);
    expect(find.text('02'), findsOneWidget);
  });

  testWidgets('搜索过滤食堂', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '一食堂');
    await tester.pumpAndSettle();

    expect(find.text('一食堂二楼'), findsOneWidget);
    expect(find.text('二食堂'), findsNothing);
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
