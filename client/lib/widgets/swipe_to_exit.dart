import 'dart:ui';

import 'package:flutter/material.dart';

import '../utils/screen_swipe.dart';

class SwipeToExit extends StatefulWidget {
  final Widget child;

  /// 为 false 时完全禁用退出滑动（例如输入面板打开时），避免侵入性手势
  /// 与 Emoji PageView / 输入框等子组件的手势冲突。
  final bool enabled;

  const SwipeToExit({
    super.key,
    required this.child,
    this.enabled = true,
  });

  @override
  State<SwipeToExit> createState() => _SwipeToExitState();
}

class _SwipeToExitState extends State<SwipeToExit> {
  int? _trackedPointer;
  Offset? _startPosition;

  bool _supportsSwipe(PointerDeviceKind kind) {
    return kind == PointerDeviceKind.touch ||
        kind == PointerDeviceKind.stylus ||
        kind == PointerDeviceKind.mouse ||
        kind == PointerDeviceKind.trackpad;
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (!widget.enabled) {
      _resetPointer();
      return;
    }
    if (_trackedPointer != null || !_supportsSwipe(event.kind)) return;
    _trackedPointer = event.pointer;
    _startPosition = event.position;
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _trackedPointer) return;
    final startPosition = _startPosition;
    _resetPointer();
    if (!widget.enabled || startPosition == null) return;

    final shouldExit = isLeftPageExitSwipe(
      start: startPosition,
      end: event.position,
      screenWidth: MediaQuery.sizeOf(context).width,
    );
    if (shouldExit) {
      Navigator.maybePop(context);
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer == _trackedPointer) {
      _resetPointer();
    }
  }

  void _resetPointer() {
    _trackedPointer = null;
    _startPosition = null;
  }

  @override
  void didUpdateWidget(covariant SwipeToExit oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled) {
      _resetPointer();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: widget.child,
    );
  }
}
