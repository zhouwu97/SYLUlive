import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'liquid_glass_runtime.dart';
import 'liquid_glass_scene.dart';

Future<ui.FragmentProgram>? _program;

/// Shared shader code, but each mounted navigation owns its mutable uniforms.
Future<ui.FragmentProgram> loadLiquidGlassProgram() =>
    _program ??= ui.FragmentProgram.fromAsset('shaders/liquid_glass.frag');

class LiquidGlassRenderer extends StatefulWidget {
  const LiquidGlassRenderer({
    super.key,
    required this.lens,
    required this.press,
    this.bend = Offset.zero,
    this.stretch = 0,
    this.angle = 0,
    this.energy = 0,
    required this.pointer,
    required this.labels,
    required this.icons,
    required this.badges,
    required this.accent,
    this.compare = false,
    this.blur = 6,
    this.tint,
  });

  final Rect lens;
  final double press;

  final Offset bend;
  final double stretch;
  final double angle;
  final double energy;
  final Offset pointer;
  final List<String> labels;
  final List<IconData> icons;
  final Map<int, bool> badges;
  final Color accent;
  final bool compare;
  final double blur;
  final double? tint;

  @override
  State<LiquidGlassRenderer> createState() => _LiquidGlassRendererState();
}

class _LiquidGlassRendererState extends State<LiquidGlassRenderer> {
  final _paintKey = GlobalKey();
  final _resources = _GlassResources();
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    loadLiquidGlassProgram().then(
      (program) {
        if (mounted) setState(() => _shader = program.fragmentShader());
      },
      onError: (Object error) {
        updateLiquidGlassRuntimeStatus(
          tier: LiquidGlassTier.c,
          shaderSupported: false,
          detail: 'Shader unavailable: $error',
        );
      },
    );
  }

  @override
  void dispose() {
    _shader?.dispose();
    _resources.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final source = LiquidGlassScene.maybeOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return CustomPaint(
      key: _paintKey,
      painter: _GlassPainter(
        source: source,
        paintKey: _paintKey,
        resources: _resources,
        shader: _shader,
        settings: widget,
        dark: dark,
        dpr: MediaQuery.devicePixelRatioOf(context),
        textScale: MediaQuery.textScalerOf(context).scale(12) / 12,
        highContrast: MediaQuery.highContrastOf(context),
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _GlassResources {
  ui.Image? atlas;
  ui.Image? capture;
  ui.Image? blurred;
  Object? atlasSignature;

  void dispose() {
    atlas?.dispose();
    capture?.dispose();
    blurred?.dispose();
  }
}

class _GlassPainter extends CustomPainter {
  _GlassPainter({
    required this.source,
    required this.paintKey,
    required this.resources,
    required this.shader,
    required this.settings,
    required this.dark,
    required this.dpr,
    required this.textScale,
    required this.highContrast,
  }) : super(repaint: source);

  final LiquidGlassSceneSource? source;
  final GlobalKey paintKey;
  final _GlassResources resources;
  final ui.FragmentShader? shader;
  final LiquidGlassRenderer settings;
  final bool dark;
  final double dpr;
  final double textScale;
  final bool highContrast;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final dock = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(32),
    );
    canvas.drawShadow(
      Path()..addRRect(dock),
      Colors.black.withValues(alpha: dark ? .5 : .22),
      10,
      true,
    );
    final shader = this.shader;
    final box = paintKey.currentContext?.findRenderObject();
    LiquidGlassCapture? capture;
    if (shader != null && box is RenderBox && source != null) {
      try {
        // Only rasterize the band behind the control. The 48px guard includes
        // Gaussian blur, displaced samples, and the expanded 78px lens.
        capture = source!.capture(box, (Offset.zero & size).inflate(48), dpr);
      } catch (error) {
        updateLiquidGlassRuntimeStatus(
          tier: LiquidGlassTier.c,
          shaderSupported: true,
          detail: 'Background capture unavailable: $error',
        );
      }
    }
    if (shader == null || capture == null) {
      _fallback(canvas, size, dock);
      if (source == null) {
        updateLiquidGlassRuntimeStatus(
          tier: LiquidGlassTier.c,
          shaderSupported: shader != null,
          detail: 'Wrap the page in LiquidGlassScene',
        );
      }
      return;
    }

    final oldCapture = resources.capture;
    final oldBlurred = resources.blurred;
    resources.capture = capture.image;
    final ratio = capture.image.width / capture.rect.width;
    // Pressed glass sheds its frosted veil while retaining the optical surface.
    final activation = settings.press.clamp(0.0, 1.0);
    final blur = settings.blur * (1.0 - .8 * activation);
    final recorder = ui.PictureRecorder();
    final blurCanvas = Canvas(recorder);
    blurCanvas.saveLayer(
      null,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: blur * ratio,
          sigmaY: blur * ratio,
          tileMode: TileMode.clamp,
        ),
    );
    blurCanvas.drawImage(capture.image, Offset.zero, Paint());
    blurCanvas.restore();
    final picture = recorder.endRecording();
    resources.blurred = picture.toImageSync(
      capture.image.width,
      capture.image.height,
    );
    picture.dispose();
    _ensureAtlas(size);
    shader.setImageSampler(0, resources.blurred!);
    shader.setImageSampler(1, resources.atlas!);
    // Inverse of reference jellyMatrix: stretch along velocity, compress across
    // it. Determinant is one, so moving faster does not inflate the glass volume.
    final along = 1 + settings.stretch;
    final across = 1 / along;
    final c = math.cos(settings.angle), s = math.sin(settings.angle);
    final a = along * c * c + across * s * s;
    final b = (along - across) * c * s;
    final d = along * s * s + across * c * c;
    final values = <double>[
      size.width,
      size.height,
      capture.rect.left,
      capture.rect.top,
      capture.rect.width,
      capture.rect.height,
      settings.lens.left,
      settings.lens.top,
      settings.lens.width,
      settings.lens.height,
      settings.pointer.dx,
      settings.pointer.dy,
      settings.press,
      dark ? 1 : 0,
      24,
      24,
      14,
      10,
      .5,
      ((settings.tint ?? (dark ? .52 : .58)) * (1.0 - .78 * activation)
          + (highContrast ? .12 : 0)).clamp(0.0, 1.0),
      settings.compare ? 1 : 0,
      dpr,
      settings.bend.dx,
      settings.bend.dy,
      d,
      -b,
      -b,
      a,
      settings.energy,
    ];
    for (var i = 0; i < values.length; i++) {
      shader.setFloat(i, values[i]);
    }
    canvas.drawRect((Offset.zero & size).inflate(48), Paint()..shader = shader);
    oldCapture?.dispose();
    oldBlurred?.dispose();
    updateLiquidGlassRuntimeStatus(
      tier: LiquidGlassTier.a,
      shaderSupported: true,
      detail: 'Live scene + tab atlas · GPU refraction',
    );
  }

  void _ensureAtlas(Size size) {
    final signature = Object.hash(
      size,
      dark,
      textScale,
      dpr,
      settings.accent,
      Object.hashAll(
        settings.badges.entries.map((e) => Object.hash(e.key, e.value)),
      ),
      Object.hashAll(settings.labels),
      Object.hashAll(settings.icons),
    );
    if (resources.atlasSignature == signature) return;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(dpr.clamp(1.0, 3.0));
    _drawTabs(canvas, size, false);
    canvas.translate(0, 64);
    _drawTabs(canvas, size, true);
    final picture = recorder.endRecording();
    final previous = resources.atlas;
    resources.atlas = picture.toImageSync(
      (size.width * dpr.clamp(1.0, 3.0)).ceil(),
      (128 * dpr.clamp(1.0, 3.0)).ceil(),
    );
    resources.atlasSignature = signature;
    picture.dispose();
    previous?.dispose();
  }

  void _drawTabs(Canvas canvas, Size size, bool accent) {
    final color = accent
        ? settings.accent
        : (dark ? const Color(0xffd1d5db) : const Color(0xff4b525e));
    final item = (size.width - 8) / settings.labels.length;
    for (var i = 0; i < settings.labels.length; i++) {
      final center = 4 + (i + .5) * item;
      final icon = settings.icons[i];
      final iconPainter = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(icon.codePoint),
          style: TextStyle(
            fontFamily: icon.fontFamily,
            package: icon.fontPackage,
            fontSize: 24,
            color: color,
            height: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      iconPainter.paint(canvas, Offset(center - iconPainter.width / 2, 12));
      iconPainter.dispose();
      final label = TextPainter(
        text: TextSpan(
          text: settings.labels[i],
          style: TextStyle(
            fontFamily: 'NotoSansCJKsc',
            fontSize: 11 * textScale.clamp(1.0, 1.6),
            fontWeight: FontWeight.w600,
            color: color,
            height: 1.1,
          ),
        ),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: item - 4);
      label.paint(canvas, Offset(center - label.width / 2, 39));
      label.dispose();
      if (settings.badges[i] == true) {
        canvas.drawCircle(
          Offset(center + 12, 13),
          4,
          Paint()..color = const Color(0xffff4d58),
        );
      }
    }
  }

  void _fallback(Canvas canvas, Size size, RRect dock) {
    canvas.drawRRect(
      dock,
      Paint()..color = dark ? const Color(0xff252a32) : const Color(0xffedf0f5),
    );
    _drawTabs(canvas, size, false);
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(settings.lens, const Radius.circular(40)),
    );
    canvas.drawRRect(
      dock,
      Paint()..color = dark ? const Color(0xff39434e) : const Color(0xffdce5f0),
    );
    _drawTabs(canvas, size, true);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlassPainter oldDelegate) => true;
}
