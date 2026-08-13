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
  group('CanteenProvider 菜品图库', () {
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

    test('submitDishPhoto 成功返回 message', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://test'));
      dio.httpClientAdapter = FakeAdapter((options) async {
        expect(options.path, '/canteens/3/dish-photos');
        return _json('{"message":"已提交审核","photo":{"id":9}}', 201);
      });
      final provider = CanteenProvider(dio);
      final message = await provider.submitDishPhoto(
        3,
        dishName: '锅包肉',
        fileId: 9527,
      );
      expect(message, '已提交审核');
      expect(provider.errorCode, isNull);
    });

    test('submitDishPhoto 409 gallery_full 暴露 errorCode', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://test'));
      dio.httpClientAdapter = FakeAdapter((options) async {
        return _json('{"code":"dish_gallery_full","error":"该菜品已有3张审核实拍"}', 409);
      });
      final provider = CanteenProvider(dio);
      final message = await provider.submitDishPhoto(
        3,
        dishId: 12,
        fileId: 9527,
      );
      expect(message, isNull);
      expect(provider.errorCode, 'dish_gallery_full');
    });

    test('adminListPendingDishPhotos 解析 items', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://test'));
      dio.httpClientAdapter = FakeAdapter((options) async {
        return _json(
          '{"items":[{"photo_id":5,"dish_name":"锅包肉","canteen_name":"一食堂",'
          '"image":"/uploads/a.jpg","approved_count":2}]}',
          200,
        );
      });
      final provider = CanteenProvider(dio);
      final items = await provider.adminListPendingDishPhotos();
      expect(items, hasLength(1));
      expect(items[0]['dish_name'], '锅包肉');
    });

    test('adminApproveDishPhoto 返回成功 + gallery_full code', () async {
      var calls = 0;
      final dio = Dio(BaseOptions(baseUrl: 'http://test'));
      dio.httpClientAdapter = FakeAdapter((options) async {
        calls++;
        if (calls == 1) return _json('{"message":"已通过"}', 200);
        return _json('{"code":"dish_gallery_full"}', 409);
      });
      final provider = CanteenProvider(dio);

      expect(await provider.adminApproveDishPhoto(5), '已通过');
      expect(await provider.adminApproveDishPhoto(6), isNull);
      expect(provider.errorCode, 'dish_gallery_full');
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
  });
}
