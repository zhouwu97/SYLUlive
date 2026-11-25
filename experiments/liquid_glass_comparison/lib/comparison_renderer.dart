import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'reference/widgets/liquid_glass/liquid_glass_scene.dart';

// The common comparison host follows the reference renderer's texture layout,
// blur/tint activation, tab atlas and uniforms. See licenses/ for provenance.
class LensPose {
  const LensPose({
    required this.position,
    required this.press,
    required this.stretch,
    required this.angle,
    required this.bend,
    required this.vertical,
    required this.energy,
  });

  final double position, press, stretch, angle, vertical, energy;
  final Offset bend;
}

class ComparisonRenderer extends StatefulWidget {
  const ComparisonRenderer({
    super.key,
    required this.program,
    required this.pose,
    required this.dockWidth,
    required this.pointer,
    required this.refined,
    required this.refineShape,
    required this.clear,
    required this.blurOnly,
  });

  final ui.FragmentProgram program;
  final LensPose pose;
  final double dockWidth;
  final Offset pointer;
  final bool refined, refineShape, clear, blurOnly;

  static const labels = ['首页', '集市', '课表', '校园', '我'];
  static const icons = [
    Icons.home_rounded,
    Icons.storefront_rounded,
    Icons.calendar_month_rounded,
    Icons.apartment_rounded,
    Icons.person_rounded,
  ];

  @override
  State<ComparisonRenderer> createState() => _ComparisonRendererState();
}

class _ComparisonRendererState extends State<ComparisonRenderer> {
  final _paintKey = GlobalKey();
  final _resources = _Textures();
  late ui.FragmentShader _shader;

  @override
  void initState() {
    super.initState();
    _shader = widget.program.fragmentShader();
  }

  @override
  void didUpdateWidget(ComparisonRenderer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.program != widget.program) {
      _shader.dispose();
      _shader = widget.program.fragmentShader();
    }
  }

  @override
  void dispose() {
    _shader.dispose();
    _resources.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    key: _paintKey,
    size: Size(widget.dockWidth + 96, 160),
    painter: _ComparisonPainter(
      settings: widget,
      source: LiquidGlassScene.maybeOf(context),
      paintKey: _paintKey,
      resources: _resources,
      shader: _shader,
      dark: Theme.of(context).brightness == Brightness.dark,
      dpr: MediaQuery.devicePixelRatioOf(context),
    ),
  );
}

class _Textures {
  ui.Image? capture, blurred, atlas;
  Object? atlasSignature;

  void dispose() {
    capture?.dispose();
    blurred?.dispose();
    atlas?.dispose();
  }
}

class _ComparisonPainter extends CustomPainter {
  _ComparisonPainter({
    required this.settings,
    required this.source,
    required this.paintKey,
    required this.resources,
    required this.shader,
    required this.dark,
    required this.dpr,
  }) : super(repaint: source);

  final ComparisonRenderer settings;
  final LiquidGlassSceneSource? source;
  final GlobalKey paintKey;
  final _Textures resources;
  final ui.FragmentShader shader;
  final bool dark;
  final double dpr;

  @override
  void paint(Canvas canvas, Size size) {
    final box = paintKey.currentContext?.findRenderObject();
    if (box is! RenderBox || source == null) return;
    final capture = source!.capture(box, Offset.zero & size, dpr);
    if (capture == null) return;
    final oldCapture = resources.capture;
    final oldBlurred = resources.blurred;
    resources.capture = capture.image;
    resources.blurred = null;
    final pose = settings.pose;
    final activation = pose.press.clamp(0.0, 1.0);
    final blur = (settings.clear ? 0.0 : 6.0) * (1 - .8 * activation);
    ui.Image scene = capture.image;
    // The refined clear path binds the captured texture directly.
    if (!settings.refined || blur > 0) {
      final ratio = capture.image.width / capture.rect.width;
      final recorder = ui.PictureRecorder();
      final target = Canvas(recorder);
      target.saveLayer(
        null,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: blur * ratio,
            sigmaY: blur * ratio,
            tileMode: TileMode.clamp,
          ),
      );
      target.drawImage(capture.image, Offset.zero, Paint());
      target.restore();
      final picture = recorder.endRecording();
      scene = resources.blurred = picture.toImageSync(
        capture.image.width,
        capture.image.height,
      );
      picture.dispose();
    }
    _atlas();
    shader.setImageSampler(0, scene);
    shader.setImageSampler(1, resources.atlas!);
    final along = 1 + pose.stretch, across = 1 / along;
    final c = math.cos(pose.angle), s = math.sin(pose.angle);
    final a = along * c * c + across * s * s;
    final b = (along - across) * c * s;
    final d = along * s * s + across * c * c;
    final item = (settings.dockWidth - 8) / 5;
    final scale = 1 + (78 / 56 - 1) * pose.press;
    final lens = Rect.fromCenter(
      center: Offset(
        4 + (pose.position.clamp(-.12, 4.12) + .5) * item,
        32 + pose.vertical,
      ),
      width:
          item *
          (settings.refined && settings.refineShape
              ? 1 + .075 * pose.press
              : scale),
      height: 56 * scale,
    );
    final rect = capture.rect.shift(const Offset(-48, -48));
    final tint =
        (settings.clear ? .06 : (dark ? .52 : .58)) * (1 - .78 * activation);
    final values = <double>[
      settings.dockWidth,
      64,
      rect.left,
      rect.top,
      rect.width,
      rect.height,
      lens.left,
      lens.top,
      lens.width,
      lens.height,
      settings.pointer.dx,
      settings.pointer.dy,
      pose.press,
      dark ? 1 : 0,
      24,
      24,
      14,
      10,
      .5,
      tint,
      settings.blurOnly ? 1 : 0,
      dpr,
      pose.bend.dx,
      pose.bend.dy,
      d,
      -b,
      -b,
      a,
      pose.energy,
    ];
    for (var i = 0; i < values.length; i++) {
      shader.setFloat(i, values[i]);
    }
    canvas.save();
    canvas.translate(48, 48);
    final dock = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, settings.dockWidth, 64),
      const Radius.circular(32),
    );
    canvas.drawShadow(
      Path()..addRRect(dock),
      Colors.black.withValues(alpha: dark ? .5 : .22),
      10,
      true,
    );
    canvas.drawRect(
      Rect.fromLTWH(-48, -48, size.width, size.height),
      Paint()..shader = shader,
    );
    canvas.restore();
    oldCapture?.dispose();
    oldBlurred?.dispose();
  }

  void _atlas() {
    final scale = dpr.clamp(1.0, 3.0);
    final signature = Object.hash(settings.dockWidth, dark, scale);
    if (resources.atlasSignature == signature) return;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(scale);
    for (var row = 0; row < 2; row++) {
      final color = row == 1
          ? (dark ? const Color(0xff84baff) : const Color(0xff1765da))
          : (dark ? const Color(0xffd1d5db) : const Color(0xff4b525e));
      final item = (settings.dockWidth - 8) / 5;
      for (var i = 0; i < 5; i++) {
        final x = 4 + (i + .5) * item;
        final icon = ComparisonRenderer.icons[i];
        final iconText = TextPainter(
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
        iconText.paint(canvas, Offset(x - iconText.width / 2, row * 64 + 12));
        iconText.dispose();
        final label = TextPainter(
          text: TextSpan(
            text: ComparisonRenderer.labels[i],
            style: TextStyle(
              fontFamily: 'NotoSansCJKsc',
              fontSize: 11,
              fontWeight: FontWeight.w600,
              height: 1.1,
              color: color,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: item - 4);
        label.paint(canvas, Offset(x - label.width / 2, row * 64 + 39));
        label.dispose();
      }
    }
    final picture = recorder.endRecording();
    final previous = resources.atlas;
    resources.atlas = picture.toImageSync(
      (settings.dockWidth * scale).ceil(),
      (128 * scale).ceil(),
    );
    resources.atlasSignature = signature;
    picture.dispose();
    previous?.dispose();
  }

  @override
  bool shouldRepaint(_ComparisonPainter oldDelegate) => true;
}
