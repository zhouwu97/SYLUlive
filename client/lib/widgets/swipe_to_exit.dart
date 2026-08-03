import 'dart:ui';

import 'package:flutter/material.dart';

import '../utils/screen_swipe.dart';

class SwipeToExit extends StatefulWidget {
  final Widget child;

  const SwipeToExit({
    super.key,
    required this.child,
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
    if (_trackedPointer != null || !_supportsSwipe(event.kind)) return;
    _trackedPointer = event.pointer;
    _startPosition = event.position;
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _trackedPointer) return;
    final startPosition = _startPosition;
    _resetPointer();
    if (startPosition == null) return;

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
