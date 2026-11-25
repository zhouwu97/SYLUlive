import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'liquid_glass_dynamics.dart';
import 'liquid_glass_scene.dart';

Future<ui.FragmentProgram>? _program;
Future<ui.FragmentProgram> loadLiquidGlassSwitchProgram() => _program ??=
    ui.FragmentProgram.fromAsset('shaders/liquid_glass_switch.frag');

/// Native input and semantics above a separately sampled glass lens.
class LiquidGlassSwitch extends StatefulWidget {
  const LiquidGlassSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    required this.source,
    required this.label,
    this.compare = false,
    this.intensity = 1,
    this.onOpticsReadyChanged,
    this.activeColor = const Color(0xff2ad34d),
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final LiquidGlassSceneSource source;
  final String label;
  final bool compare;
  final double intensity;
  final ValueChanged<bool>? onOpticsReadyChanged;
  final Color activeColor;

  @override
  State<LiquidGlassSwitch> createState() => _LiquidGlassSwitchState();
}

class _LiquidGlassSwitchState extends State<LiquidGlassSwitch>
    with TickerProviderStateMixin {
  late final LiquidGlassDynamics _motion;
  late final AnimationController _color;
  final _focus = FocusNode();
  final _paintKey = GlobalKey();
  final _resources = _SwitchResources();
  ui.FragmentShader? _shader;
  int? _pointer;
  Offset _start = Offset.zero, _light = const Offset(40, 0);
  double _startIndex = 0, _colorTarget = 0;
  bool _ready = false, _opticalGesture = false, _verticalCancelled = false;
  bool _tapCandidate = false;
  bool? _pendingReady;
  bool get _reduced => MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    _motion = LiquidGlassDynamics(
        vsync: this, index: widget.value ? 1 : 0, directFollowRate: 100)
      ..configure(20)
      ..addListener(_onMotion);
    _colorTarget = widget.value ? 1 : 0;
    _color = AnimationController(
        vsync: this,
        value: _colorTarget,
        duration: const Duration(milliseconds: 160));
    loadLiquidGlassSwitchProgram().then((program) {
      if (mounted) setState(() => _shader = program.fragmentShader());
    }, onError: (Object _) => _reportReady(false));
  }

  void _onMotion() {
    final target = _motion.position >= .5 ? 1.0 : 0.0;
    if (target != _colorTarget) {
      _colorTarget = target;
      if (_reduced) {
        _color.value = target;
      } else {
        _color.animateTo(target,
            curve: Curves.easeOut,
            duration: Duration(milliseconds: _motion.isTapping ? 139 : 160));
      }
    }
    if (!_motion.isMoving && _pointer == null) _opticalGesture = false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion.reduced = _reduced;
    _motion.intensity = widget.intensity;
    if (_reduced) _motion.snapTo(widget.value ? 1 : 0);
  }

  @override
  void didUpdateWidget(LiquidGlassSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    _motion.intensity = widget.intensity;
    if (oldWidget.value != widget.value &&
        (!_motion.isTapping ||
            _motion.tapDestination != (widget.value ? 1 : 0))) {
      _motion.releaseTo(widget.value ? 1 : 0);
    }
    if (widget.onChanged == null && _pointer != null) {
      _cancel();
    }
  }

  void _down(PointerDownEvent event) {
    if (widget.onChanged == null ||
        _pointer != null ||
        event.buttons & kPrimaryButton == 0) {
      return;
    }
    _pointer = event.pointer;
    _start = event.position;
    _startIndex = _motion.position.clamp(0, 1);
    _light = event.localPosition;
    _verticalCancelled = false;
    _tapCandidate = true;
    _opticalGesture = true;
    _motion.grab();
  }

  void _move(PointerMoveEvent event) {
    if (_pointer != event.pointer || _verticalCancelled) return;
    final delta = event.position - _start;
    if (delta.dx.abs() > kTouchSlop) _tapCandidate = false;
    if (delta.dy.abs() > kTouchSlop && delta.dy.abs() > delta.dx.abs()) {
      _verticalCancelled = true;
      _tapCandidate = false;
      _opticalGesture = false;
      _motion.releaseTo(widget.value ? 1 : 0);
      return;
    }
    _light = event.localPosition;
    _motion.dragTo((_startIndex + delta.dx / 20).clamp(0, 1),
        pullY: (delta.dy * .12).clamp(-3, 3));
  }

  void _cancel() {
    _tapCandidate = false;
    _pointer = null;
    _opticalGesture = false;
    _motion.releaseTo(widget.value ? 1 : 0);
  }

  void _up(PointerUpEvent event) {
    if (!mounted || _pointer != event.pointer) return;
    _pointer = null;
    if (!_tapCandidate && !_motion.isTapping) {
      _motion.releaseTo(widget.value ? 1 : 0);
    }
  }

  void _commit(bool value) {
    if (!mounted) return;
    if (_tapCandidate) {
      _motion.tapTo(value ? 1 : 0);
    } else {
      _motion.releaseTo(value ? 1 : 0);
    }
    _tapCandidate = false;
    widget.onChanged?.call(value);
  }

  void _reportReady(bool ready) {
    if (!mounted || _ready == ready || _pendingReady == ready) return;
    _pendingReady = ready;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final next = _pendingReady;
      _pendingReady = null;
      if (next == null) return;
      setState(() => _ready = next);
      widget.onOpticsReadyChanged?.call(next);
    });
  }

  @override
  void dispose() {
    _motion.dispose();
    _color.dispose();
    _focus.dispose();
    _shader?.dispose();
    _resources.image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final highContrast = MediaQuery.highContrastOf(context);
    final enabled = widget.onChanged != null;
    return SizedBox(
      width: 72,
      height: 48,
      child: Stack(clipBehavior: Clip.none, fit: StackFit.expand, children: [
        IgnorePointer(
          child: CustomPaint(
            key: _paintKey,
            painter: _SwitchPainter(
              repaint:
                  Listenable.merge([_motion, _color, _focus, widget.source]),
              motion: _motion,
              color: _color,
              source: widget.source,
              resources: _resources,
              paintKey: _paintKey,
              shader: enabled && !highContrast ? _shader : null,
              ready: _reportReady,
              pointer: () => _light,
              opticalGesture: () => _opticalGesture,
              focused: () =>
                  _focus.hasFocus &&
                  FocusManager.instance.highlightMode ==
                      FocusHighlightMode.traditional,
              onColor: widget.activeColor,
              offColor: theme.brightness == Brightness.dark
                  ? const Color(0xff5b586a)
                  : const Color(0xffcfcbd3),
              compare: widget.compare,
              dpr: MediaQuery.devicePixelRatioOf(context),
            ),
          ),
        ),
        Listener(
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: _up,
          onPointerCancel: (event) {
            if (mounted && _pointer == event.pointer) _cancel();
          },
          child: Semantics(
            label: widget.label,
            child: Opacity(
              opacity: _ready && enabled && !highContrast ? 0 : 1,
              alwaysIncludeSemantics: true,
              child: Switch(
                value: widget.value,
                onChanged: enabled ? _commit : null,
                activeTrackColor: highContrast ? null : widget.activeColor,
                inactiveTrackColor: highContrast
                    ? null
                    : theme.brightness == Brightness.dark
                        ? const Color(0xff5b586a)
                        : const Color(0xffcfcbd3),
                activeThumbColor: highContrast ? null : Colors.white,
                inactiveThumbColor: highContrast ? null : Colors.white,
                trackOutlineColor: highContrast
                    ? null
                    : const WidgetStatePropertyAll(Colors.transparent),
                focusNode: _focus,
                dragStartBehavior: DragStartBehavior.down,
                materialTapTargetSize: MaterialTapTargetSize.padded,
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _SwitchResources {
  ui.Image? image;
  Rect? rect;
}

class _SwitchPainter extends CustomPainter {
  _SwitchPainter(
      {required Listenable repaint,
      required this.motion,
      required this.color,
      required this.source,
      required this.resources,
      required this.paintKey,
      required this.shader,
      required this.ready,
      required this.pointer,
      required this.opticalGesture,
      required this.focused,
      required this.onColor,
      required this.offColor,
      required this.compare,
      required this.dpr})
      : super(repaint: repaint);

  final LiquidGlassDynamics motion;
  final Animation<double> color;
  final LiquidGlassSceneSource source;
  final _SwitchResources resources;
  final GlobalKey paintKey;
  final ui.FragmentShader? shader;
  final ValueChanged<bool> ready;
  final Offset Function() pointer;
  final bool Function() opticalGesture, focused;
  final Color onColor, offColor;
  final bool compare;
  final double dpr;

  @override
  void paint(Canvas canvas, Size size) {
    final shader = this.shader;
    final box = paintKey.currentContext?.findRenderObject();
    if (shader == null || box is! RenderBox) {
      ready(false);
      return;
    }
    ui.Image? old;
    if (resources.image == null || motion.pressure > .001 || opticalGesture()) {
      final capture =
          source.capture(box, (Offset.zero & size).inflate(40), dpr);
      if (capture == null) {
        ready(false);
        return;
      }
      old = resources.image;
      resources.image = capture.image;
      resources.rect = capture.rect;
      shader.setImageSampler(0, capture.image);
    }
    final rect = resources.rect!;
    final track = Color.lerp(offColor, onColor, color.value)!;
    final center = Offset(
        size.width / 2 - 10 + 20 * motion.position.clamp(0, 1),
        size.height / 2);
    final activation = motion.pressure.clamp(0.0, 1.0);
    final glass = (activation + (opticalGesture() ? motion.energy * 2 : 0))
        .clamp(0.0, 1.0);
    final pressure = motion.pressure.clamp(0.0, 1.16);
    final half = Size(15 + 11 * pressure, 12 + 4 * pressure);
    final stretch = motion.stretch.clamp(-.025, .04);
    final light = pointer();
    final values = <double>[
      size.width,
      size.height,
      rect.left,
      rect.top,
      rect.width,
      rect.height,
      center.dx,
      center.dy,
      half.width,
      half.height,
      light.dx,
      light.dy,
      activation,
      stretch,
      motion.bend.dx,
      motion.bend.dy,
      motion.energy,
      compare ? 1 : 0,
      dpr,
      .85,
      track.r,
      track.g,
      track.b,
    ];
    for (var i = 0; i < values.length; i++) {
      shader.setFloat(i, values[i]);
    }
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: size.center(Offset.zero), width: 56, height: 30),
            const Radius.circular(15)),
        Paint()..color = track);
    final thumb = Rect.fromCenter(
        center: center,
        width: half.width * 2 * (1 + stretch),
        height: half.height * 2 / (1 + stretch));
    canvas.drawRRect(
        RRect.fromRectAndRadius(thumb, Radius.circular(thumb.height / 2)),
        Paint()..color = Colors.white.withValues(alpha: 1 - glass));
    final bounds = (Offset.zero & size).inflate(14);
    canvas.saveLayer(
        bounds, Paint()..color = Colors.white.withValues(alpha: glass));
    canvas.drawRect(bounds, Paint()..shader = shader);
    canvas.restore();
    if (focused()) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromCenter(
                  center: size.center(Offset.zero), width: 64, height: 38),
              const Radius.circular(19)),
          Paint()
            ..color = onColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    }
    old?.dispose();
    ready(true);
  }

  @override
  bool shouldRepaint(_SwitchPainter old) => true;
}
