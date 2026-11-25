import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// The background is recorded separately, so glass can never sample itself.
/// Put the entire scrollable page in [background], and the navigation in [overlay].
class LiquidGlassScene extends StatefulWidget {
  const LiquidGlassScene({
    super.key,
    required this.background,
    required this.overlay,
  });

  final Widget background;
  final Widget overlay;

  static LiquidGlassSceneSource? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SceneScope>()?.source;

  @override
  State<LiquidGlassScene> createState() => _LiquidGlassSceneState();
}

class _LiquidGlassSceneState extends State<LiquidGlassScene> {
  final source = LiquidGlassSceneSource();

  @override
  void initState() {
    super.initState();
    // Persistent callbacks do not request frames. During an existing frame this
    // only invalidates the glass paint; scrolling/animated descendants therefore
    // stay live without a timer, async readback or an idle capture loop.
    final weakSource = WeakReference(source);
    SchedulerBinding.instance.addPersistentFrameCallback((_) {
      weakSource.target?.frameChanged();
    });
  }

  @override
  void dispose() {
    source.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _SceneScope(
    source: source,
    child: Stack(
      fit: StackFit.expand,
      children: [
        _CaptureBoundary(key: source.key, child: widget.background),
        widget.overlay,
      ],
    ),
  );
}

class _SceneScope extends InheritedWidget {
  const _SceneScope({required this.source, required super.child});
  final LiquidGlassSceneSource source;

  @override
  bool updateShouldNotify(_SceneScope oldWidget) => oldWidget.source != source;
}

class LiquidGlassCapture {
  const LiquidGlassCapture(this.image, this.rect);
  final ui.Image image;

  /// Capture bounds in the glass painter's local logical coordinates.
  final Rect rect;
}

class _CaptureBoundary extends SingleChildRenderObjectWidget {
  const _CaptureBoundary({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCaptureBoundary();
}

class _RenderCaptureBoundary extends RenderRepaintBoundary {
  ui.Image? captureRegion(Rect bounds, double dpr) {
    final currentLayer = layer;
    if (currentLayer is! OffsetLayer) return null;
    return currentLayer.toImageSync(bounds, pixelRatio: dpr);
  }
}

class LiquidGlassSceneSource extends ChangeNotifier {
  final key = GlobalKey();
  bool _disposed = false;

  void frameChanged() {
    if (!_disposed) notifyListeners();
  }

  LiquidGlassCapture? capture(RenderBox glass, Rect localBounds, double dpr) {
    final background = key.currentContext?.findRenderObject();
    if (background is! _RenderCaptureBoundary || !background.hasSize) {
      return null;
    }
    final origin = background.globalToLocal(glass.localToGlobal(Offset.zero));
    final bounds = localBounds
        .shift(origin)
        .intersect(Offset.zero & background.size);
    if (bounds.isEmpty) return null;
    final image = background.captureRegion(bounds, dpr.clamp(1.0, 2.0));
    if (image == null) return null;
    return LiquidGlassCapture(image, bounds.shift(-origin));
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
