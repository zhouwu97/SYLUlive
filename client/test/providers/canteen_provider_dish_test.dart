import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';

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

void main() {
  group('CanteenProvider 菜品图库与治理', () {
    test('loadDishes 解析菜品列表', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://test'));
      dio.httpClientAdapter = FakeAdapter((options) async {
        return _json(
          '[{"id":1,"name":"锅包肉","cover_image":"/uploads/a.jpg",'
          '"photo_count":3,"last_photo_at":"2026-08-13T10:00:00"},'
          '{"id":2,"name":"麻辣香锅","cover_image":"","photo_count":0,'
          '"last_photo_at":""}]',
          200,
        );
      });
      final provider = CanteenProvider(dio);
      final dishes = await provider.loadDishes(1);

      expect(dishes, isNotNull);
      expect(dishes, hasLength(2));
      expect(dishes![0].name, '锅包肉');
      expect(dishes[0].photoCount, 3);
      expect(dishes[1].coverImage, '');
    });

    test('loadDishes 成功但为空返回 []（区别于失败）', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://test'));
      dio.httpClientAdapter = FakeAdapter((options) async {
        return _json('[]', 200);
      });
      final provider = CanteenProvider(dio);
      final dishes = await provider.loadDishes(1);

      expect(dishes, isNotNull);
      expect(dishes, isEmpty);
    });

    test('loadDishes 网络失败返回 null（不伪装成空列表）', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://test'));
      dio.httpClientAdapter = FakeAdapter((options) async {
        return _json('{"error":"internal"}', 500);
      });
      final provider = CanteenProvider(dio);
      final dishes = await provider.loadDishes(1);

      expect(dishes, isNull);
    });

    test('adminUpdateDish 发送 name', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://test'));
      String? sentPath;
      dio.httpClientAdapter = FakeAdapter((options) async {
        sentPath = '${options.method} ${options.path}';
        return _json('{"message":"已更新"}', 200);
      });
      final provider = CanteenProvider(dio);
      final ok = await provider.adminUpdateDish(12, name: '新菜名');
      expect(ok, isTrue);
      expect(sentPath, 'PATCH /canteens/dishes/12');
    });

    test('adminArchiveDishPhoto 下架实拍', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://test'));
      String? sentPath;
      dio.httpClientAdapter = FakeAdapter((options) async {
        sentPath = '${options.method} ${options.path}';
        return _json('{"message":"已下架"}', 200);
      });
      final provider = CanteenProvider(dio);
      final ok = await provider.adminArchiveDishPhoto(8);
      expect(ok, isTrue);
      expect(sentPath, 'POST /canteens/dish-photos/8/archive');
    });

    test('adminMergeDish 合并菜品', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://test'));
      String? sentPath;
      dio.httpClientAdapter = FakeAdapter((options) async {
        sentPath = '${options.method} ${options.path}';
        return _json('{"message":"已合并"}', 200);
      });
      final provider = CanteenProvider(dio);
      final ok = await provider.adminMergeDish(10, 12);
      expect(ok, isTrue);
      expect(sentPath, 'POST /canteens/dishes/10/merge');
    });
  });
}
