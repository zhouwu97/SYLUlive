import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/providers/canteen_discovery_provider.dart';
import 'package:shenliyuan/widgets/canteen/canteen_ranking_filter.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions) handler;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
          Future<void>? cancelFuture) =>
      handler(options);
  @override
  void close({bool force = false}) {}
}

ResponseBody _ranking(String floor) => ResponseBody.fromString(
      '{"items":[{"id":34,"name":"川渝椒香","location_area":"一食堂",'
      '"location_floor":"$floor","summary_tags":[]}],"meta":{"total":1}}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType]
      },
    );

void main() {
  test('强制刷新重新请求，位置筛选立即采用新楼层', () async {
    var calls = 0;
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter =
        _Adapter((_) async => _ranking(++calls == 1 ? '一楼' : '二楼'));
    final provider = CanteenDiscoveryProvider(dio);
    await provider.loadRanking();
    await provider.loadRanking();
    expect(calls, 1);
    await provider.loadRanking(forceRefresh: true);
    expect(calls, 2);
    expect(
        canteenRankingItemMatchesLocation(
            provider.rankingItems.single, '一食堂', '二楼'),
        isTrue);
    expect(
        canteenRankingItemMatchesLocation(
            provider.rankingItems.single, '', '一楼'),
        isFalse);
  });

  test('修改标签前的旧请求不能覆盖修改后的新数据', () async {
    final old = Completer<ResponseBody>();
    final started = Completer<void>();
    var calls = 0;
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = _Adapter((_) {
      if (++calls == 1) {
        started.complete();
        return old.future;
      }
      return Future.value(_ranking('二楼'));
    });
    final provider = CanteenDiscoveryProvider(dio);
    final first = provider.loadRanking();
    await started.future;
    provider.invalidateRanking();
    await provider.loadRanking();
    expect(provider.rankingItems.single.locationFloor, '二楼');
    old.complete(_ranking('一楼'));
    await first;
    expect(provider.rankingItems.single.locationFloor, '二楼');
    expect(calls, 2);
  });

  test('同时刷新同一个排序只发送一次请求', () async {
    final pending = Completer<ResponseBody>();
    final started = Completer<void>();
    var calls = 0;
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = _Adapter((_) {
      calls++;
      if (!started.isCompleted) started.complete();
      return pending.future;
    });
    final provider = CanteenDiscoveryProvider(dio);
    final a = provider.loadRanking(forceRefresh: true);
    final b = provider.loadRanking(forceRefresh: true);
    await started.future;
    expect(calls, 1);
    pending.complete(_ranking('二楼'));
    await Future.wait([a, b]);
    expect(provider.rankingLoading, isFalse);
  });

  test('首页旧请求在标签保存后失效', () async {
    final old = Completer<ResponseBody>();
    final started = Completer<void>();
    var calls = 0;
    ResponseBody home(String title) => ResponseBody.fromString(
          '{"feed":[{"id":"canteen:34","type":"canteen","canteen_id":34,"title":"$title"}]}',
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType]
          },
        );
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.httpClientAdapter = _Adapter((_) {
      if (++calls == 1) {
        started.complete();
        return old.future;
      }
      return Future.value(home('新标签'));
    });
    final provider = CanteenDiscoveryProvider(dio);
    final first = provider.loadHome();
    await started.future;
    provider.invalidateRanking();
    await provider.loadHome();
    old.complete(home('旧标签'));
    await first;
    expect(provider.home.feed.single.title, '新标签');
  });
}
