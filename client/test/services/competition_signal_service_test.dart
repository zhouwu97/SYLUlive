import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/competition.dart';
import 'package:shenliyuan/services/competition_signal_service.dart';

class _SignalAdapter implements HttpClientAdapter {
  _SignalAdapter(this.handler);

  final FutureOr<ResponseBody> Function(RequestOptions options, String body)
      handler;
  final List<Map<String, dynamic>> bodies = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = <int>[];
    await for (final chunk in requestStream ?? const Stream.empty()) {
      bytes.addAll(chunk);
    }
    final body = utf8.decode(bytes);
    bodies.add(Map<String, dynamic>.from(jsonDecode(body) as Map));
    return handler(options, body);
  }
}

ResponseBody _ok() => ResponseBody.fromString(
      jsonEncode({'accepted': 1}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

Dio _dio(_SignalAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
  dio.httpClientAdapter = adapter;
  return dio;
}

CompetitionEvent _event(
  int id, {
  String tier = 'strong',
  String basis = 'major_cluster',
}) {
  return CompetitionEvent(
    id: id,
    competitionId: 'NAT-$id',
    title: '比赛 $id',
    matchTier: tier,
    matchBasis: basis,
  );
}

void main() {
  test('曝光按会话去重，同一赛事不重复上报', () async {
    final adapter = _SignalAdapter((_, __) => _ok());
    final service = CompetitionSignalService(_dio(adapter));
    service.startSession();

    await service.recordImpressions([_event(1), _event(2)], algorithmVersion: 'v1');
    // 再次传入同样的赛事（模拟滚动回看）不应产生新的上报。
    await service.recordImpressions([_event(1), _event(2)], algorithmVersion: 'v1');

    expect(adapter.bodies.length, 1);
    final signals = adapter.bodies.single['signals'] as List;
    expect(signals.length, 2);
    expect(adapter.bodies.single['session_key'], isNotEmpty);
    expect(adapter.bodies.single['algorithm_version'], 'v1');
  });

  test('上报内容包含位次与离散匹配档位，且不含分值与内部字段', () async {
    final adapter = _SignalAdapter((_, __) => _ok());
    final service = CompetitionSignalService(_dio(adapter));
    service.startSession();

    await service.recordClick(
      _event(7, tier: 'suitable', basis: 'college'),
      position: 3,
      algorithmVersion: 'major-match-v1',
    );

    final signal =
        (adapter.bodies.single['signals'] as List).single as Map<String, dynamic>;
    expect(signal['event_id'], 7);
    expect(signal['competition_id'], 'NAT-7');
    expect(signal['kind'], 'candidate_click');
    expect(signal['position'], 3);
    expect(signal['match_tier'], 'suitable');
    expect(signal['match_basis'], 'college');
    expect(signal.containsKey('match_score'), isFalse);
  });

  test('超过单批上限时分批上报', () async {
    final adapter = _SignalAdapter((_, __) => _ok());
    final service = CompetitionSignalService(_dio(adapter));
    service.startSession();

    await service.recordImpressions(
      [for (var id = 1; id <= 70; id++) _event(id)],
      algorithmVersion: 'v1',
    );

    // 70 条按 30 一批切分：30 + 30 + 10。
    expect(adapter.bodies.length, 3);
    final sizes = adapter.bodies
        .map((body) => (body['signals'] as List).length)
        .toList();
    expect(sizes, [30, 30, 10]);
  });

  test('上报失败被静默吞掉，不向调用方抛异常', () async {
    final adapter = _SignalAdapter(
      (_, __) => ResponseBody.fromString('{"error":"boom"}', 500,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          }),
    );
    final service = CompetitionSignalService(_dio(adapter));
    service.startSession();

    // 埋点失败不得影响用户操作：不抛异常是最低要求。
    await service.recordImpressions([_event(1)], algorithmVersion: 'v1');
    await service.recordFitTabExposure(algorithmVersion: 'v1');
    expect(adapter.bodies.length, 2);
  });

  test('换会话后曝光重新计数', () async {
    final adapter = _SignalAdapter((_, __) => _ok());
    final service = CompetitionSignalService(_dio(adapter));
    service.startSession();
    await service.recordImpressions([_event(1)], algorithmVersion: 'v1');

    service.startSession();
    await service.recordImpressions([_event(1)], algorithmVersion: 'v1');

    expect(adapter.bodies.length, 2);
    expect(
      adapter.bodies[0]['session_key'] == adapter.bodies[1]['session_key'],
      isFalse,
    );
  });
}
