import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

// Motion equations ported from DayDreamInAReverie/design-systems:
// jelly.js, jelly-physics.js and optical-motion.js (MIT, Copyright 2026).
// Navigation-specific changes: bounded horizontal rail, measured pressure,
// logical-pixel sizing, and no animation when reduced motion is requested.
class LiquidGlassDynamics extends ChangeNotifier {
  LiquidGlassDynamics({required TickerProvider vsync, double index = 0}) {
    _x.snap(index);
    _ticker = vsync.createTicker(_tick);
  }

  late final Ticker _ticker;
  final _x = _Spring();
  final _y = _Spring();
  final _press = _Spring();
  final _stretch = _Spring();
  final _bendX = _Spring();
  final _bendY = _Spring();
  Duration? _last;
  double _itemWidth = 1;
  double _angle = 0;
  bool _held = false;
  bool _tapActive = false, _tapPosition = false;
  double _heldSeconds = 0,
      _tapSeconds = 0,
      _tapLift = 0,
      _tapFrom = 0,
      _tapTo = 0;
  bool reduced = false;
  double intensity = 1;
  bool get isMoving =>
      _tapActive ||
      [_x, _y, _press, _stretch, _bendX, _bendY].any((s) => s.moving);
  bool get isTapping => _tapActive;
  double get tapDestination => _tapTo / _itemWidth;
  double get position => _x.value / _itemWidth;
  double get pressure => reduced ? 0 : _press.value.clamp(0, 1.16) * intensity;
  double get stretch =>
      reduced ? 0 : _stretch.value.clamp(-.20, .34) * intensity;
  double get angle => reduced ? 0 : _angle;
  Offset get bend =>
      reduced ? Offset.zero : Offset(_bendX.value, _bendY.value) * intensity;
  double get energy => stretch.abs() + bend.distance * .015;
  double get vertical => reduced ? 0 : _y.value * intensity;
  double get speed =>
      math.sqrt(_x.velocity * _x.velocity + _y.velocity * _y.velocity);

  void configure(double itemWidth) {
    if (_itemWidth == itemWidth) return;
    final ratio = itemWidth / _itemWidth;
    _x.value *= ratio;
    _x.target *= ratio;
    _x.velocity *= ratio;
    _itemWidth = itemWidth;
  }

  void grab({double pressure = 1}) {
    _tapActive = _tapPosition = false;
    _heldSeconds = 0;
    _held = true;
    _x.target = _x.value;
    _press.target = pressure;
    _wake();
  }

  void dragTo(double index, {double pullY = 0, double pressure = 1}) {
    _held = true;
    _x.target = index.clamp(0, 4) * _itemWidth;
    _y.target = pullY.clamp(-10, 10);
    _press.target = pressure;
    _wake();
  }

  void releaseTo(double index) {
    _tapActive = _tapPosition = false;
    _held = false;
    _x.target = index * _itemWidth;
    _y.target = 0;
    _press.target = 0;
    // Keep all velocities. A reversal or release changes forces, not momentum.
    _wake();
  }

  /// Complete a quick tap as a compressed press, travel and release gesture.
  /// The native switch still owns the semantic commit on pointer-up.
  void tapTo(double index) {
    if (reduced) {
      snapTo(index);
      return;
    }
    _held = false;
    _tapFrom = _x.value;
    _tapTo = index * _itemWidth;
    _tapSeconds = 0;
    _tapLift = math.max(0, .14 - _heldSeconds);
    _tapActive = _tapPosition = true;
    _x.target = _tapFrom;
    _y.target = 0;
    _press.target = 1;
    _wake();
  }

  void snapTo(double index) {
    _tapActive = _tapPosition = false;
    _held = false;
    _x.snap(index * _itemWidth);
    for (final spring in [_y, _press, _stretch, _bendX, _bendY]) {
      spring.snap(0);
    }
    _ticker.stop();
    _last = null;
    notifyListeners();
  }

  void _wake() {
    if (reduced) {
      snapTo(_x.target / _itemWidth);
    } else if (!_ticker.isActive) {
      _last = null;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final dt = _last == null ? 1 / 60 : (elapsed - _last!).inMicroseconds / 1e6;
    _last = elapsed;
    // Bounded substeps, including after a missed frame; no frame-rate-dependent
    // lerp and no restart of the clock when a new pointer event arrives.
    advance(dt.clamp(0, .08));
    notifyListeners();
    if (!isMoving) {
      _ticker.stop();
      _last = null;
    }
  }

  @visibleForTesting
  void advance(double dt) {
    var remaining = dt;
    while (remaining > 1e-9) {
      final realStep = math.min(remaining, 1 / 180);
      final h = realStep * (_tapPosition ? 1.15 : 1);
      if (_held) _heldSeconds += realStep;
      if (_tapActive) {
        _tapSeconds += h;
        final t = ((_tapSeconds - _tapLift) / .28).clamp(0.0, 1.0);
        _x.target = _tapFrom + (_tapTo - _tapFrom) * t * t * (3 - 2 * t);
        if (t == 1 &&
            (_tapTo - _x.value).abs() < .4 &&
            _x.velocity.abs() < 12) {
          _tapActive = false;
          _press.target = 0;
        }
      }
      final damping = _held ? 22.0 : 17.0;
      _x.step(h, _tapPosition ? 700 : 260, _tapPosition ? 54 : damping);
      _y.step(h, 260, damping);
      _press.step(h, 310, _tapPosition && !_tapActive ? 24 : 18);
      if (speed > 16) _angle = math.atan2(_y.velocity, _x.velocity);
      _stretch.target = math.min(speed / 2400, .25);
      _stretch.step(h, _tapPosition ? 300 : 230, _tapPosition ? 24 : 15);
      _bendX.target = ((_x.target - _x.value) * .12).clamp(-11, 11);
      _bendY.target = ((_y.target - _y.value) * .12).clamp(-11, 11);
      _bendX.step(h, _tapPosition ? 300 : 190, _tapPosition ? 24 : 14);
      _bendY.step(h, 190, 14);
      remaining -= realStep;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

class _Spring {
  double value = 0, velocity = 0, target = 0;
  bool get moving => velocity.abs() > .025 || (target - value).abs() > .005;
  void step(double dt, double stiffness, double damping) {
    velocity += ((target - value) * stiffness - velocity * damping) * dt;
    value += velocity * dt;
    if (!moving) snap(target);
  }

  void snap(double to) {
    value = target = to;
    velocity = 0;
  }
}
