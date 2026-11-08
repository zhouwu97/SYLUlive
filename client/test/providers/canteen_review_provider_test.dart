import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/canteen_review.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';

class _FakeAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions options) handler;

  _FakeAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(String body, int status) => ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

const _dimensions = CanteenReviewDimensions(
  taste: 5,
  value: 4,
  queue: 3,
  hygiene: 4,
  service: 4,
);

void main() {
  test('本人数量遍历全部游标页，区分旧评价并去除跨页重复', () async {
    final queries = <Map<String, dynamic>>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://test'))
      ..httpClientAdapter = _FakeAdapter((o) async {
        queries.add(Map.of(o.queryParameters));
        return _json(
            jsonEncode(o.queryParameters['cursor'] == null
                ? {
                    'items': [
                      {'id': 7},
                      {'id': 7, 'source': 'legacy', 'legacy_rating_id': 7}
                    ],
                    'count': 2,
                    'has_more': true,
                    'next_cursor': 'page2',
                  }
                : {
                    'items': [
                      {'id': 7},
                      {'id': 8}
                    ],
                    'count': 2,
                    'has_more': false,
                  }),
            200);
      });
    expect(
        await CanteenProvider(dio).countMyCanteenReviews(isCurrent: () => true),
        3);
    expect(queries, [
      {'limit': 50},
      {'limit': 50, 'cursor': 'page2'}
    ]);
  });

  for (final broken in ['error', 'missing-cursor', 'repeated-cursor']) {
    test('不完整的食堂统计保持未知 $broken', () async {
      var requests = 0;
      final dio = Dio(BaseOptions(baseUrl: 'http://test'))
        ..httpClientAdapter = _FakeAdapter((o) async {
          requests++;
          if (broken == 'error' && requests > 1) {
            return _json('{"error":"失败"}', 503);
          }
          return _json(
              jsonEncode({
                'items': [
                  {'id': requests}
                ],
                'has_more': true,
                if (broken != 'missing-cursor') 'next_cursor': 'same',
              }),
              200);
        });
      expect(
          await CanteenProvider(dio)
              .countMyCanteenReviews(isCurrent: () => true),
          isNull);
      expect(requests, broken == 'missing-cursor' ? 1 : 2);
    });
  }

  test('统计等待期间账号改变，不读取下一页或提交旧数量', () async {
    final gate = Completer<ResponseBody>();
    var current = true;
    var requests = 0;
    final dio = Dio(BaseOptions(baseUrl: 'http://test'))
      ..httpClientAdapter = _FakeAdapter((o) {
        requests++;
        return gate.future;
      });
    final result =
        CanteenProvider(dio).countMyCanteenReviews(isCurrent: () => current);
    await Future<void>.delayed(Duration.zero);
    current = false;
    gate.complete(_json(
        '{"items":[{"id":1}],"has_more":true,"next_cursor":"more"}', 200));
    expect(await result, isNull);
    expect(requests, 1);
  });

  test('deleteReview 使用 source 区分 V2 与 legacy URL', () async {
    final paths = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://test'))
      ..httpClientAdapter = _FakeAdapter((options) async {
        paths.add('${options.method} ${options.path}');
        return _json('{"already_deleted":false}', 200);
      });
    final provider = CanteenProvider(dio);

    expect((await provider.deleteReview(id: 7, source: 'v2')).success, isTrue);
    expect(
        (await provider.deleteReview(id: 8, source: 'legacy')).success, isTrue);
    expect(paths, ['DELETE /canteens/reviews/7', 'DELETE /canteens/ratings/8']);
  });

  test('deleteReview 解析 403/409 code', () async {
    var status = 403;
    final dio = Dio(BaseOptions(baseUrl: 'http://test'))
      ..httpClientAdapter = _FakeAdapter((_) async {
        final body = status == 403
            ? '{"code":"review_forbidden","error":"只能删除自己的评价"}'
            : '{"code":"review_not_active","error":"评价当前不可操作"}';
        return _json(body, status);
      });
    final provider = CanteenProvider(dio);

    final forbidden = await provider.deleteReview(id: 1, source: 'v2');
    expect(forbidden.success, isFalse);
    expect(forbidden.errorCode, 'review_forbidden');
    status = 409;
    final conflict = await provider.deleteReview(id: 1, source: 'v2');
    expect(conflict.success, isFalse);
    expect(conflict.errorCode, 'review_not_active');
  });

  test('updateReview 兼容 review_conflict 并返回 remote_updated_at', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'))
      ..httpClientAdapter = _FakeAdapter((_) async => _json(
            '{"code":"review_conflict","error":"评价已在其他设备更新",'
            '"remote_updated_at":"2026-08-23T10:00:00Z"}',
            409,
          ));
    final provider = CanteenProvider(dio);
    final result = await provider.updateReview(
      9,
      dimensions: _dimensions,
      comment: '草稿',
      baseUpdatedAt: DateTime.utc(2026, 8, 23, 9),
    );

    expect(result.success, isFalse);
    expect(result.errorCode, 'review_conflict');
    expect(result.remoteUpdatedAt, DateTime.utc(2026, 8, 23, 10));
  });

  test('updateReview 读取统一错误格式 message 字段展示真实原因', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'))
      ..httpClientAdapter = _FakeAdapter((_) async => _json(
            '{"code":"invalid_review_dish",'
            '"message":"invalid_review_dish: 图片已绑定到其他菜品",'
            '"request_id":"req-1"}',
            400,
          ));
    final provider = CanteenProvider(dio);
    final result = await provider.updateReview(
      9,
      dimensions: _dimensions,
      comment: '修改',
    );

    expect(result.success, isFalse);
    expect(result.errorCode, 'invalid_review_dish');
    expect(result.errorMessage, 'invalid_review_dish: 图片已绑定到其他菜品');
  });
}
