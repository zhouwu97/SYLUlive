import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../models/reply.dart';
import '../../services/post_reply_reads.dart';

class VisibleReplyBody extends StatelessWidget {
  const VisibleReplyBody({super.key, required this.reply, required this.child});

  final Reply reply;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reads = context.watch<PostReplyReads?>();
    final revision = reads?.watchRevision(reply.id);
    if (revision == null || reply.isDeleted) return child;
    return _Dwell(
      key: ValueKey((reads, reply.id, revision)),
      onSeen: () => reads!.seen(reply.id),
      child: child,
    );
  }
}

class _Dwell extends StatefulWidget {
  const _Dwell({super.key, required this.onSeen, required this.child});

  final VoidCallback onSeen;
  final Widget child;

  @override
  State<_Dwell> createState() => _DwellState();
}

class _DwellState extends State<_Dwell> with WidgetsBindingObserver {
  final _visibilityKey = UniqueKey();
  final _body = GlobalKey();
  VisibilityInfo? _info;
  ScrollPosition? _position;
  bool _current = false;
  bool _reported = false;
  Timer? _timer;
  late double _screenHeight;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (!identical(position, _position)) {
      _position?.isScrollingNotifier.removeListener(_update);
      _position = position;
      position?.isScrollingNotifier.addListener(_update);
    }
    _current = (ModalRoute.isCurrentOf(context) ?? true) &&
        TickerMode.valuesOf(context).enabled;
    _screenHeight = MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom;
    _update();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _update();

  bool get _visible {
    final info = _info;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (!_current ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed) ||
        _position?.isScrollingNotifier.value == true ||
        info == null ||
        info.visibleBounds.isEmpty) {
      return false;
    }
    final viewport = _position?.hasViewportDimension == true
        ? math.min(_screenHeight, _position!.viewportDimension)
        : _screenHeight;
    return info.visibleBounds.width >= info.size.width / 2 &&
        info.visibleBounds.height >= math.min(info.size.height, viewport) / 2;
  }

  void _update() {
    if (!_visible) {
      _timer?.cancel();
      _timer = null;
      _reported = false;
    } else if (!_reported) {
      _timer ??= Timer(const Duration(milliseconds: 700), () {
        _timer = null;
        if (!mounted || !_visible) return;
        // 弹层、键盘和分栏的覆盖层不一定裁剪底层绘制，实际命中正文才提交。
        final box = _body.currentContext?.findRenderObject() as RenderBox?;
        if (box == null || !box.attached || !box.hasSize) return;
        final point = box.localToGlobal(_info!.visibleBounds.center);
        final hit = HitTestResult();
        WidgetsBinding.instance
            .hitTestInView(hit, point, View.of(context).viewId);
        if (hit.path.any((entry) => identical(entry.target, box))) {
          _reported = true;
          widget.onSeen();
        }
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _position?.isScrollingNotifier.removeListener(_update);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => VisibilityDetector(
        key: _visibilityKey,
        onVisibilityChanged: (info) {
          if (!mounted) return;
          _info = info;
          _update();
        },
        child: Listener(
            key: _body,
            behavior: HitTestBehavior.translucent,
            child: widget.child),
      );
}
