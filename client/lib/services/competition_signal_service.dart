import 'dart:math';

import 'package:dio/dio.dart';

import '../models/competition.dart';

/// 竞赛候选链路的埋点上报。
///
/// 为什么要有它：没有曝光分母就算不出转化率，也无法区分「没推荐到」与
/// 「推荐了但没人点」——两者要修的东西完全不同。
///
/// 三条硬约束（都是踩过的坑）：
/// - **埋点绝不阻塞用户操作**：任何失败都吞掉，不弹提示、不改状态、不 await 到 UI 流程里；
/// - **曝光同一会话内去重**：滚动导致同一条赛事多次进入视口，只应记一次，
///   否则曝光数会随滚动次数膨胀，CTR 被系统性低估；
/// - **`kind` 必须用服务端白名单里的取值**：写错的值会被接口拒绝，
///   而在客户端拼字符串时没有任何编译期保护。
class CompetitionSignalService {
  CompetitionSignalService(this._dio);

  final Dio _dio;
  final Random _random = Random();

  static const String _path = '/user/competitions/candidate-signals';
  static const int _maxBatchSize = 30;

  /// 会话标识：同一次「适合我」浏览共用一个，进入 tab 或重新加载时重置。
  String _sessionKey = '';
  final Set<int> _sentImpressions = {};

  String get sessionKey => _sessionKey;

  /// 开始一次新的浏览会话。曝光去重集合随之清空。
  void startSession() {
    _sessionKey =
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '${_random.nextInt(1 << 32).toRadixString(36)}';
    _sentImpressions.clear();
  }

  Future<void> recordFitTabExposure({String algorithmVersion = ''}) {
    return _send(
      algorithmVersion: algorithmVersion,
      signals: [
        {'kind': 'fit_tab_exposure', 'position': 0},
      ],
    );
  }

  /// 记录一批「进入了视口」的候选。调用方传入的顺序即展示顺序，索引即位次。
  Future<void> recordImpressions(
    List<CompetitionEvent> events, {
    String algorithmVersion = '',
  }) async {
    final fresh = <Map<String, dynamic>>[];
    for (var index = 0; index < events.length; index++) {
      final event = events[index];
      if (event.id == 0 || _sentImpressions.contains(event.id)) continue;
      _sentImpressions.add(event.id);
      fresh.add(_signal(event, 'candidate_impression', index));
    }
    if (fresh.isEmpty) return;
    for (var start = 0; start < fresh.length; start += _maxBatchSize) {
      final end = min(start + _maxBatchSize, fresh.length);
      await _send(
        algorithmVersion: algorithmVersion,
        signals: fresh.sublist(start, end),
      );
    }
  }

  Future<void> recordMatchReasonOpen(
    CompetitionEvent event, {
    int position = 0,
    String algorithmVersion = '',
  }) {
    return _send(
      algorithmVersion: algorithmVersion,
      signals: [_signal(event, 'match_reason_open', position)],
    );
  }

  Future<void> recordClick(
    CompetitionEvent event, {
    int position = 0,
    String algorithmVersion = '',
  }) {
    return _send(
      algorithmVersion: algorithmVersion,
      signals: [_signal(event, 'candidate_click', position)],
    );
  }

  Future<void> recordCalendarAdd(
    CompetitionEvent event, {
    int position = 0,
    String algorithmVersion = '',
  }) {
    return _send(
      algorithmVersion: algorithmVersion,
      signals: [_signal(event, 'calendar_add', position)],
    );
  }

  Map<String, dynamic> _signal(
    CompetitionEvent event,
    String kind,
    int position,
  ) {
    return {
      'event_id': event.id,
      'competition_id': event.competitionId,
      'kind': kind,
      'position': position,
      'match_tier': event.matchTier,
      'match_basis': event.matchBasis,
    };
  }

  Future<void> _send({
    required List<Map<String, dynamic>> signals,
    required String algorithmVersion,
  }) async {
    if (_sessionKey.isEmpty) startSession();
    try {
      await _dio.post(
        _path,
        data: {
          'session_key': _sessionKey,
          'algorithm_version': algorithmVersion,
          'signals': signals,
        },
      );
    } catch (_) {
      // 埋点失败必须静默：用户此刻在意的是比赛列表，不是我们的指标。
    }
  }
}
