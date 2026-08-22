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
}
