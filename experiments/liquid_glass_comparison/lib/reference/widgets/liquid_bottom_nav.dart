import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'bottom_nav.dart' show BottomNav;
import 'liquid_glass/bottom_nav_controller.dart';
import 'liquid_glass/liquid_glass_renderer.dart';
import 'liquid_glass/liquid_glass_dynamics.dart';
import 'liquid_glass/liquid_glass_tilt.dart';
export 'liquid_glass/bottom_nav_controller.dart';
export 'liquid_glass/liquid_glass_scene.dart';

/// One physical pill. The optical position is continuous; navigation commits on release.
class BottomNavWrapper extends StatefulWidget {
  const BottomNavWrapper({
    super.key,
    required this.currentIndex,
    required this.visualIndexListenable,
    required this.onTap,
    this.onNavigationCommitted,
    this.badges = const {},
    this.compare = false,
    this.blur = 6,
    this.tint,
  });
  final int currentIndex;
  final ValueNotifier<double> visualIndexListenable;
  final ValueChanged<int> onTap;
  final ValueChanged<int>? onNavigationCommitted;
  final Map<int, bool> badges;
  final bool compare;
  final double blur;
  final double? tint;
  @override
  State<BottomNavWrapper> createState() => _BottomNavWrapperState();
}

class _BottomNavWrapperState extends State<BottomNavWrapper>
    with TickerProviderStateMixin {
  late final AnimationController _recoil;
  late final LiquidGlassDynamics _fluid;
  late final BottomNavController _drag;
  late final Listenable _motion;
  final GlobalKey _dockKey = GlobalKey();
  final _tilt = LiquidGlassTilt();
  int? _pointerId;
  int? _committedTarget;
  bool _dragging = false;
  bool _startedOnLens = false;
  bool _publishing = false;
  bool _keyboardFocus = false;
  double _itemWidth = 1;
  double _grabOffset = 0;
  double _startX = 0;
  double _startY = 0;
  double _speed = 0;
  Offset _light = const Offset(40, 0);
  VelocityTracker? _tracker;
  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    _drag = BottomNavController(
      itemCount: 5,
      initialIndex: widget.currentIndex,
    );
    _fluid = LiquidGlassDynamics(
      vsync: this,
      index: widget.currentIndex.toDouble(),
    )..addListener(_publish);
    _recoil = AnimationController.unbounded(vsync: this);
    _motion = Listenable.merge([_fluid, _recoil, _tilt]);
    widget.visualIndexListenable.addListener(_externalPosition);
  }

  void _publish() {
    _publishing = true;
    widget.visualIndexListenable.value = _fluid.position.clamp(0, 4).toDouble();
    _publishing = false;
  }

  void _externalPosition() {
    if (!_publishing) {
      _fluid.releaseTo(
        widget.visualIndexListenable.value.clamp(0, 4).toDouble(),
      );
    }
  }

  @override
  void didUpdateWidget(BottomNavWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visualIndexListenable != widget.visualIndexListenable) {
      oldWidget.visualIndexListenable.removeListener(_externalPosition);
      widget.visualIndexListenable.addListener(_externalPosition);
    }
    if (oldWidget.currentIndex != widget.currentIndex) {
      if (_committedTarget != widget.currentIndex) {
        _pointerId = null;
        _dragging = false;
        _settle(widget.currentIndex);
      }
      _committedTarget = null;
    }
  }

  @override
  void dispose() {
    widget.visualIndexListenable.removeListener(_externalPosition);
    _recoil.dispose();
    _fluid.dispose();
    _tilt.dispose();
    super.dispose();
  }

  void _spring(
    AnimationController controller,
    double to, {
    double stiffness = 700,
    double damping = 48,
  }) {
    final velocity = controller.velocity;
    controller.stop();
    if (_reduceMotion) {
      controller.value = to;
      return;
    }
    unawaited(
      controller
          .animateWith(
            SpringSimulation(
              SpringDescription(
                mass: 1,
                stiffness: stiffness,
                damping: damping,
              ),
              controller.value,
              to,
              velocity,
            ),
          )
          .orCancel
          .catchError((Object _) {}),
    );
  }

  Offset _local(PointerEvent event) =>
      (_dockKey.currentContext!.findRenderObject()! as RenderBox).globalToLocal(
        event.position,
      );
  int _index(double x) => ((x - 4) / _itemWidth).floor().clamp(0, 4);
  double _pressure(PointerEvent event) {
    // Mouse clicks and common touch devices report a constant 1. Treat that
    // as the reference's ordinary held state, not invented force measurement.
    final range = event.pressureMax - event.pressureMin;
    if (event.kind == PointerDeviceKind.mouse ||
        range <= 0 ||
        (event.pressureMax == 1 && event.pressure == 1)) {
      return 1;
    }
    return .65 +
        .51 * ((event.pressure - event.pressureMin) / range).clamp(0, 1);
  }

  void _down(PointerDownEvent event) {
    if (_pointerId != null || event.buttons != kPrimaryButton) return;
    final p = _local(event);
    _pointerId = event.pointer;
    _recoil.stop();
    _startX = p.dx;
    _startY = p.dy;
    _light = p;
    _speed = 0;
    final center = 4 + (_fluid.position + .5) * _itemWidth;
    _grabOffset = p.dx - center;
    _startedOnLens = _grabOffset.abs() <= _itemWidth * .7;
    _tracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
    if (!_startedOnLens) {
      // A new press owns the lens immediately, but never commits navigation.
      final target = _index(p.dx);
      _fluid.snapTo(target.toDouble());
      _grabOffset = p.dx - (4 + (target + .5) * _itemWidth);
      _startedOnLens = true;
    }
    _fluid.grab(pressure: _pressure(event));
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointerId) return;
    final p = _local(event);
    _tracker?.addPosition(event.timeStamp, event.position);
    if (!_dragging && (p.dx - _startX).abs() >= 4) {
      _dragging = true;
      _drag.configureTrack(
        itemWidth: _itemWidth,
        trackLeft: 4 + _itemWidth / 2,
        trackRight: 4 + _itemWidth * 4.5,
      );
      _drag.beginDrag(_fluid.position.clamp(0, 4).toDouble());
      if (!_startedOnLens) _grabOffset = 0;
    }
    if (!_dragging) {
      if (_startedOnLens) _fluid.grab(pressure: _pressure(event));
      return;
    }
    final measured = _tracker!.getVelocity().pixelsPerSecond.dx;
    _speed = (_speed * .5 + measured * .5).clamp(-3000, 3000);
    _drag.updateDragFromCenter(
      centerX: p.dx - _grabOffset,
      velocityPixelsPerSecond: _speed,
    );
    _light = p;
    _fluid.dragTo(
      _drag.position,
      pullY: (p.dy - _startY) * .25,
      pressure: _pressure(event),
    );
    final delta = (p.dx - _startX) / 120;
    _recoil.value = _reduceMotion ? 0 : 4 * delta / (1 + delta.abs());
    setState(() {});
  }

  void _up(PointerUpEvent event) {
    if (event.pointer != _pointerId) return;
    _tracker?.addPosition(event.timeStamp, event.position);
    final velocity = _tracker?.getVelocity().pixelsPerSecond.dx ?? 0;
    final target = _dragging
        ? _drag.endDrag(
            velocityPixelsPerSecond: velocity,
            itemWidth: _itemWidth,
          )
        : _index(_local(event).dx);
    _pointerId = null;
    _tracker = null;
    _dragging = false;
    _commit(target);
    _settle(target);
  }

  void _cancel(PointerCancelEvent event) {
    if (event.pointer != _pointerId) return;
    _pointerId = null;
    _tracker = null;
    _dragging = false;
    _drag.cancelDrag(widget.currentIndex.toDouble());
    _settle(widget.currentIndex);
  }

  void _commit(int target) {
    _committedTarget = target;
    (widget.onNavigationCommitted ?? widget.onTap)(target);
  }

  void _settle(int target) {
    _spring(_recoil, 0, stiffness: 300, damping: 34.64);
    _speed = 0;
    _fluid.releaseTo(target.toDouble());
  }

  void _accessibleSelect(int index) {
    _recoil.stop();
    _pointerId = null;
    _dragging = false;
    _fluid.snapTo(index.toDouble());
    _recoil.value = 0;
    _commit(index);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    int? target;
    if (key == LogicalKeyboardKey.arrowRight) target = widget.currentIndex + 1;
    if (key == LogicalKeyboardKey.arrowLeft) target = widget.currentIndex - 1;
    if (key == LogicalKeyboardKey.home) target = 0;
    if (key == LogicalKeyboardKey.end) target = 4;
    if (target == null) return KeyEventResult.ignored;
    _accessibleSelect(target.clamp(0, 4));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Align(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Focus(
              onKeyEvent: _key,
              onFocusChange: (value) => setState(() => _keyboardFocus = value),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  _itemWidth = (width - 8) / 5;
                  _fluid.configure(_itemWidth);
                  _fluid.reduced = _reduceMotion;
                  return AnimatedBuilder(
                    animation: _motion,
                    builder: (context, _) {
                      final press = _fluid.pressure;
                      final scale = 1 + (78 / 56 - 1) * press;
                      final lens = Rect.fromCenter(
                        center: Offset(
                          4 +
                              (_fluid.position.clamp(-.12, 4.12) + .5) *
                                  _itemWidth,
                          32 + _fluid.vertical,
                        ),
                        width: _itemWidth * scale,
                        height: 56 * scale,
                      );
                      return Transform.translate(
                        offset: Offset(_recoil.value, 0),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          onHover: (event) =>
                              setState(() => _light = event.localPosition),
                          child: Listener(
                            behavior: HitTestBehavior.opaque,
                            onPointerDown: _down,
                            onPointerMove: _move,
                            onPointerUp: _up,
                            onPointerCancel: _cancel,
                            child: SizedBox(
                              key: const ValueKey('bottom-nav-floating-dock'),
                              height: 64,
                              child: Stack(
                                key: _dockKey,
                                clipBehavior: Clip.none,
                                children: [
                                  Positioned.fill(
                                    child: RepaintBoundary(
                                      child: LiquidGlassRenderer(
                                        lens: lens,
                                        press: press,
                                        bend: _fluid.bend,
                                        stretch: _fluid.stretch,
                                        angle: _fluid.angle,
                                        energy: _fluid.energy,
                                        pointer:
                                            _light +
                                            (_reduceMotion
                                                ? Offset.zero
                                                : _tilt.value * width * .8),
                                        labels: BottomNav.labels,
                                        icons: BottomNav.icons,
                                        badges: widget.badges,
                                        accent: dark
                                            ? const Color(0xff84baff)
                                            : const Color(0xff1765da),
                                        compare: widget.compare,
                                        blur: widget.blur,
                                        tint: widget.tint,
                                      ),
                                    ),
                                  ),
                                  Positioned.fromRect(
                                    rect: lens,
                                    child: const IgnorePointer(
                                      child: SizedBox(
                                        key: ValueKey('bottom-nav-selection'),
                                      ),
                                    ),
                                  ),
                                  if (_keyboardFocus)
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(
                                              32,
                                            ),
                                            border: Border.all(
                                              color: const Color(0xff438cf5),
                                              width: 2,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  Positioned.fill(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                      ),
                                      child: Row(
                                        children: List.generate(
                                          5,
                                          (index) => Expanded(
                                            child: Semantics(
                                              key: ValueKey(
                                                'bottom-nav-semantic-$index',
                                              ),
                                              label:
                                                  '${BottomNav.labels[index]}${widget.badges[index] == true ? '，有新消息' : ''}',
                                              button: true,
                                              selected:
                                                  widget.currentIndex == index,
                                              onTap: () =>
                                                  _accessibleSelect(index),
                                              child: SizedBox.expand(
                                                key: ValueKey(
                                                  'bottom-nav-item-$index',
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
