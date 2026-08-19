import 'dart:async';

import 'package:dio/dio.dart';

import '../config/api_constants.dart';

/// 单条 Feed 行为事件（FEED-3 客户端口径，与服务端 FEED-2 对齐）。
class FeedEvent {
  const FeedEvent({
    required this.feedSessionId,
    required this.feedKind,
    required this.algorithmVersion,
    required this.type,
    required this.postId,
    this.position = 0,
    this.visibleMs = 0,
    this.dwellMs = 0,
  });

  final String feedSessionId;
  final String feedKind;
  final String algorithmVersion;
  final String type; // impression | open | dwell
  final int postId;
  final int position;
  final int visibleMs;
  final int dwellMs;

  Map<String, dynamic> toJson() => {
        'type': type,
        'post_id': postId,
        if (position > 0) 'position': position,
        if (visibleMs > 0) 'visible_ms': visibleMs,
        if (dwellMs > 0) 'dwell_ms': dwellMs,
      };
}

/// 批量上报 Feed 行为事件（FEED-2 / FEED-3）。
///
/// 队列 + 批量（约 40 条或 5s debounce）+ 离开/后台时 flush + 内存有界重试。
/// 事件是分析数据不是业务交易：失败不抛给调用方、不弹 Toast、不阻塞浏览。
class FeedEventService {
  FeedEventService(this._dio, {int maxBatch = 40})
      : _maxBatch = maxBatch;

  final Dio _dio;
  final int _maxBatch;

  final List<FeedEvent> _queue = [];
  Timer? _flushTimer;
  int _retries = 0;

  static const Duration _flushDebounce = Duration(seconds: 5);
  static const int _maxRetries = 3;

  bool get hasPending => _queue.isNotEmpty;

  /// 当前队列中的待上报事件（测试与调试用，只读快照）。
  List<FeedEvent> get pendingEvents => List<FeedEvent>.unmodifiable(_queue);

  /// 入队一条事件；满批或 debounce 到期后触发 flush。
  void enqueue(FeedEvent event) {
    if (event.postId == 0) return;
    _queue.add(event);
    if (_queue.length >= _maxBatch) {
      flush();
      return;
    }
    _flushTimer ??= Timer(_flushDebounce, flush);
  }

  /// 立即把队列按 (session, kind, algorithm) 分组发送。失败有界重试。
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_queue.isEmpty) return;

    final batch = List<FeedEvent>.from(_queue);
    _queue.clear();

    // 按 (feed_session_id, feed_kind, algorithm_version) 分组，一次一组。
    final groups = <String, List<FeedEvent>>{};
    for (final event in batch) {
      final key = '${event.feedSessionId}|${event.feedKind}|${event.algorithmVersion}';
      (groups[key] ??= []).add(event);
    }

    var anyFailed = false;
    for (final group in groups.values) {
      final first = group.first;
      try {
        await _dio.post(
          ApiConstants.feedEventsBatchPath,
          data: {
            'feed_session_id': first.feedSessionId,
            'feed_kind': first.feedKind,
            'algorithm_version': first.algorithmVersion,
            'events': group.map((e) => e.toJson()).toList(),
          },
        );
      } catch (_) {
        anyFailed = true;
      }
    }

    if (anyFailed && _retries < _maxRetries) {
      _retries++;
      _queue.insertAll(0, batch); // 有界内存重试，不阻塞浏览
      _flushTimer ??= Timer(_flushDebounce, flush);
    } else {
      _retries = 0;
    }
  }

  /// 离开 Feed / 应用进入后台 / dispose 时调用：立即尝试清空队列。
  void flushNow() {
    unawaited(flush());
  }

  /// 释放：取消挂起的 debounce 定时器（避免测试残留 pending timer）。
  void dispose() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }
}
