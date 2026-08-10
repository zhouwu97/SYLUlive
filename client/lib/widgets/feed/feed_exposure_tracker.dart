import 'dart:async';

import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../models/post.dart';
import '../../services/feed_event_service.dart';
import '../../services/feed_session_service.dart';

/// 卡片曝光追踪（FEED-3）。
///
/// 挂载在 CommunityPostCard 外层（不要挂到 PostCard，避免 Poll 写第二套）。
/// 曝光口径：可见 ≥50% 且连续 ≥700ms。同一 feed_session_id + post_id
/// 最多提交一个有效 impression 更新（服务端本身幂等，visible_ms 取最大）。
class FeedExposureTracker extends StatefulWidget {
  const FeedExposureTracker({
    super.key,
    required this.child,
    required this.post,
    required this.feedKind,
    required this.position,
    required this.algorithmVersion,
    required this.sessionService,
    required this.eventService,
    this.minVisibleFraction = 0.5,
    this.minVisibleDuration = const Duration(milliseconds: 700),
  });

  final Widget child;
  final Post post;
  final String feedKind;
  final int position;
  final String algorithmVersion;
  final FeedSessionService sessionService;
  final FeedEventService eventService;
  final double minVisibleFraction;
  final Duration minVisibleDuration;

  @override
  State<FeedExposureTracker> createState() => _FeedExposureTrackerState();
}

class _FeedExposureTrackerState extends State<FeedExposureTracker> {
  Timer? _timer;
  String? _reportedSessionId;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    if (!mounted) return; // dispose 后可见性回调可能仍触发一次，避免重建 timer
    final visible = info.visibleFraction >= widget.minVisibleFraction;
    if (visible) {
      _timer ??= Timer(widget.minVisibleDuration, _reportImpression);
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _reportImpression() {
    if (!mounted) {
      _timer = null;
      return;
    }
    _timer = null;
    final sessionId = widget.sessionService.currentSessionId;
    if (sessionId == null) return;
    if (_reportedSessionId == sessionId) return;
    _reportedSessionId = sessionId;
    widget.eventService.enqueue(
      FeedEvent(
        feedSessionId: sessionId,
        feedKind: widget.feedKind,
        algorithmVersion: widget.algorithmVersion,
        type: 'impression',
        postId: widget.post.id,
        position: widget.position,
        visibleMs: widget.minVisibleDuration.inMilliseconds,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return VisibilityDetector(
      key: ValueKey('feed-exposure-${widget.post.id}'),
      onVisibilityChanged: _onVisibilityChanged,
      child: widget.child,
    );
  }
}
