import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bottom_nav_demo/widgets/liquid_glass/liquid_glass_renderer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('GPU lens displaces sampled pixels and preserves alpha', () async {
    final program = await loadLiquidGlassProgram();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(const Color(0xffd0e0eb), BlendMode.src);
    for (var x = 0; x < 456; x += 11) {
      canvas.drawRect(
        Rect.fromLTWH(x.toDouble(), 0, 2, 160),
        Paint()..color = const Color(0xff274766),
      );
    }
    for (var y = 0; y < 160; y += 11) {
      canvas.drawRect(
        Rect.fromLTWH(0, y.toDouble(), 456, 2),
        Paint()..color = const Color(0xff274766),
      );
    }
    final scenePicture = recorder.endRecording();
    final scene = await scenePicture.toImage(456, 160);
    scenePicture.dispose();
    final tabsRecorder = ui.PictureRecorder();
    final tabsCanvas = Canvas(tabsRecorder);
    // This stroke is part of the tab layer, not the background. Its edge must
    // refract with the scene to catch a separate, undeformed foreground overlay.
    tabsCanvas.drawRect(
      const Rect.fromLTWH(147, 14, 4, 36),
      Paint()..color = Colors.black,
    );
    tabsCanvas.drawRect(
      const Rect.fromLTWH(147, 78, 4, 36),
      Paint()..color = const Color(0xff1765da),
    );
    final tabsPicture = tabsRecorder.endRecording();
    final tabs = await tabsPicture.toImage(360, 128);
    tabsPicture.dispose();

    Future<ui.Image> render(
      bool compare, {
      double dpr = 1,
      double flow = 0,
      bool expanded = false,
    }) async {
      final shader = program.fragmentShader();
      shader.setImageSampler(0, scene);
      shader.setImageSampler(1, tabs);
      final values = <double>[
        360,
        64,
        -48,
        -48,
        456,
        160,
        140,
        -7,
        80,
        78,
        160,
        0,
        1,
        0,
        24,
        24,
        14,
        10,
        .5,
        .20,
        compare ? 1 : 0,
        dpr,
        flow * 11,
        0,
        1,
        0,
        0,
        1,
        0,
      ];
      for (var i = 0; i < values.length; i++) {
        shader.setFloat(i, values[i]);
      }
      final recorder = ui.PictureRecorder();
      final output = Canvas(recorder);
      if (expanded) output.translate(0, 24);
      output.drawRect(
        const Rect.fromLTWH(0, -24, 360, 112),
        Paint()..shader = shader,
      );
      final picture = recorder.endRecording();
      final result = await picture.toImage(360, expanded ? 112 : 64);
      picture.dispose();
      shader.dispose();
      return result;
    }

    final refracted = await render(false);
    final blurred = await render(true);
    final retina = await render(false, dpr: 3);
    Future<Uint8List> pixels(ui.Image image) async => (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List();
    final a = await pixels(refracted);
    final b = await pixels(blurred);
    final c = await pixels(retina);
    var differences = 0;
    var dprDifference = 0;
    for (var y = 16; y < 48; y++) {
      for (var x = 142; x < 158; x++) {
        final at = (y * 360 + x) * 4;
        differences += (a[at] - b[at]).abs() + (a[at + 2] - b[at + 2]).abs();
        dprDifference += (a[at] - c[at]).abs();
        expect(a[at + 3], 255);
      }
    }
    expect(
      differences / (32 * 16 * 2),
      greaterThan(8),
      reason: 'Edge samples must actually move',
    );
    expect(
      dprDifference / (32 * 16),
      lessThan(1),
      reason: 'Optical distances must stay in logical pixels',
    );
    expect(a[3], 0, reason: 'Outside the capsule stays transparent');
    final right = await render(false, flow: .85, expanded: true);
    final left = await render(false, flow: -.85, expanded: true);
    final neutral = await render(false, expanded: true);
    final rp = await pixels(right);
    final lp = await pixels(left);
    final np = await pixels(neutral);
    var changedSilhouette = 0;
    var mirrorError = 0;
    // Above the dock, alpha measures the lens itself, independent of lighting.
    // A rigid translated/scaled capsule cannot pass both directional asymmetry
    // and a mirrored response to a reversed pull.
    for (var y = 0; y < 21; y++) {
      for (var x = 130; x < 230; x++) {
        final at = (y * 360 + x) * 4 + 3;
        final mirrored = (y * 360 + 359 - x) * 4 + 3;
        if ((rp[at] - np[at]).abs() > 32) changedSilhouette++;
        mirrorError += (rp[at] - lp[mirrored]).abs();
      }
    }
    // Only the exposed top cap is counted; the dock covers the side outline.
    expect(changedSilhouette, greaterThan(12));
    expect(mirrorError / 2100, lessThan(2));
    final directory = Directory('build/verification')
      ..createSync(recursive: true);
    for (final entry in {
      'optics-refraction': refracted,
      'optics-blur-only': blurred,
      'optics-fluid-right': right,
      'optics-fluid-left': left,
      'optics-fluid-rest': neutral,
    }.entries) {
      File('${directory.path}/${entry.key}.png').writeAsBytesSync(
        (await entry.value.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List(),
      );
    }
    scene.dispose();
    tabs.dispose();
    refracted.dispose();
    blurred.dispose();
    retina.dispose();
    right.dispose();
    left.dispose();
    neutral.dispose();
  });
}
