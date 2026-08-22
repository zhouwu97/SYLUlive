import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/providers/user_calendar_provider.dart';
import 'package:shenliyuan/services/user_calendar_service.dart';

class _HoldableAdapter implements HttpClientAdapter {
  final List<({String path, Completer<ResponseBody> completer})> pending =
      <({String path, Completer<ResponseBody> completer})>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final completer = Completer<ResponseBody>();
    pending.add((path: options.path, completer: completer));
    return completer.future;
  }

  @override
  void close({bool force = false}) {}

  void completeNext(Map<String, dynamic> body) {
    if (pending.isEmpty) throw StateError('没有等待中的 HTTP 请求');
    final request = pending.removeAt(0);
    request.completer.complete(
      ResponseBody.fromString(
        jsonEncode(body),
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      ),
    );
  }
}

Dio _dio(_HoldableAdapter adapter) {
  return Dio(BaseOptions(baseUrl: 'http://test.local'))
    ..httpClientAdapter = adapter;
}

Map<String, dynamic> _eventJson({required int id, required String title}) {
  return <String, dynamic>{
    'id': id,
    'calendar_id': 1,
    'title': title,
    'description': '',
    'start_at': '2020-08-23T09:00:00Z',
    'end_at': '2020-08-23T10:00:00Z',
    'all_day': false,
    'location': '',
    'timezone': 'Asia/Shanghai',
    'source_type': 'manual',
    'created_by': 'user',
    'version': 1,
  };
}

void main() {
  test('切换账号会清空旧日历，并阻止旧请求回写当前账号', () async {
    final adapter = _HoldableAdapter();
    final provider = UserCalendarProvider(UserCalendarService(_dio(adapter)));

    provider.syncSessionUser(101, 1);
    final staleLoad = provider.load();
    await pumpEventQueue(times: 5);
    expect(adapter.pending, hasLength(1));

    provider.syncSessionUser(202, 2);
    expect(provider.events, isEmpty);

    adapter.completeNext(<String, dynamic>{
      'events': <Map<String, dynamic>>[
        _eventJson(id: 1, title: '旧账号事件'),
      ],
    });
    await staleLoad;
    expect(provider.events, isEmpty);

    final currentLoad = provider.load();
    await pumpEventQueue(times: 5);
    expect(adapter.pending, hasLength(1));
    adapter.completeNext(<String, dynamic>{
      'events': <Map<String, dynamic>>[
        _eventJson(id: 2, title: '当前账号事件'),
      ],
    });
    await currentLoad;

    expect(provider.events.single.title, '当前账号事件');
    provider.syncSessionUser(303, 3);
    expect(provider.events, isEmpty);
  });
}
