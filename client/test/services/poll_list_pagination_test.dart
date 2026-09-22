import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/poll_service.dart';

/// 投票列表分页字段的客户端解析：新服务端给出 has_more / matched_total，
/// 旧服务端没有这两个字段时必须解析成 null，而不是当成「没有下一页」。
Response<dynamic> _listResponse(RequestOptions options, Map<String, dynamic> data) =>
    Response(requestOptions: options, statusCode: 200, data: data);

Dio _dioReturning(Map<String, dynamic> Function() payload) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.resolve(_listResponse(options, payload())),
    ),
  );
  return dio;
}

void main() {
  test('读取服务端 has_more 与 matched_total', () async {
    final response = await PollService(_dioReturning(() => {
          'items': const <Map<String, dynamic>>[],
          'page': 3,
          'limit': 20,
          'total': 500,
          'matched_total': 530,
          'pool_size': 500,
          'has_more': false,
        })).listPolls(sort: 'recommend', page: 3);

    expect(response.total, 500);
    expect(response.matchedTotal, 530);
    expect(response.hasMore, isFalse);
  });

  test('旧服务端缺少分页字段时不伪造结论', () async {
    final response = await PollService(_dioReturning(() => {
          'items': const <Map<String, dynamic>>[],
          'page': 1,
          'limit': 20,
          'total': 7,
        })).listPolls();

    expect(response.hasMore, isNull);
    expect(response.matchedTotal, isNull);
    expect(response.total, 7);
  });
}
