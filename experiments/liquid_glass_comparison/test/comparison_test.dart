import 'dart:ui' as ui;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_comparison/comparison_renderer.dart';
import 'package:liquid_glass_comparison/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> openDemo(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final font = FontLoader('NotoSansCJKsc')
        ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'));
      await font.load();
      await tester.pumpWidget(const ComparisonApp());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
  }

  List<ComparisonRenderer> renderers(WidgetTester tester) => tester
      .widgetList<ComparisonRenderer>(find.byType(ComparisonRenderer))
      .toList();

  testWidgets('shared drag, low intensity, cancellation and reduced motion', (
    tester,
  ) async {
    await openDemo(tester, const Size(1280, 1000));
    expect(find.byType(ComparisonRenderer), findsNWidgets(2));
    final start = tester.getCenter(
      find.byKey(const ValueKey('reference-input')),
    );
    final gesture = await tester.startGesture(start);
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(start + Offset(i * 13, -8));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final pair = renderers(tester);
    expect(pair[0].pose.position, closeTo(pair[1].pose.position, .00001));
    expect(pair[0].pose.bend, pair[1].pose.bend);
    expect(pair[0].pose.press, greaterThan(.8));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(renderers(tester).first.pose.press, closeTo(0, .001));
    await tester.tap(find.text('保持按压'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('35%'));
    await tester.pumpAndSettle();
    for (final renderer in renderers(tester)) {
      expect(renderer.pose.press, closeTo(1, .001));
    }
    await tester.tap(find.text('减少动态'));
    await tester.pumpAndSettle();
    expect(renderers(tester).first.pose.press, 0);
    expect(renderers(tester).first.pose.bend, Offset.zero);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone layout, controls and original demo route', (tester) async {
    await openDemo(tester, const Size(390, 1000));
    await tester.tap(find.text('原版磨砂'));
    await tester.pumpAndSettle();
    expect(renderers(tester).every((r) => !r.clear), isTrue);
    await tester.tap(find.text('光学＋形变'));
    await tester.pumpAndSettle();
    expect(renderers(tester).last.refineShape, isTrue);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('打开原项目完整 demo'), 300);
    await tester.tap(find.text('打开原项目完整 demo'));
    await tester.pumpAndSettle();
    expect(find.text('触得到的光。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('system reduced motion stops active playback and held input', (
    tester,
  ) async {
    await openDemo(tester, const Size(1280, 1000));
    await tester.tap(find.text('保持按压'));
    await tester.pumpAndSettle();
    expect(renderers(tester).first.pose.press, greaterThan(.9));
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );
    await tester.pumpAndSettle();
    expect(renderers(tester).first.pose.press, 0);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton).first).onPressed,
      isNull,
    );
    tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue();
    await tester.pumpAndSettle();
    await tester.tap(find.text('播放慢拖与快甩'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('停止演示'), findsOneWidget);
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    await tester.pumpAndSettle();
    expect(find.text('停止演示'), findsNothing);
    expect(renderers(tester).first.pose.press, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  test('shader pixels preserve alpha and improve neutral transmission', () async {
    final programs = await Future.wait([
      ui.FragmentProgram.fromAsset('shaders/liquid_glass.frag'),
      ui.FragmentProgram.fromAsset('shaders/refined_glass.frag'),
    ]);
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(const Color(0xff808080), BlendMode.src);
    final scenePicture = recorder.endRecording();
    final scene = await scenePicture.toImage(456, 160);
    scenePicture.dispose();
    final inkRecorder = ui.PictureRecorder();
    Canvas(inkRecorder)
      ..drawColor(Colors.transparent, BlendMode.src)
      ..drawRect(
        const Rect.fromLTWH(320, 16, 3, 30),
        Paint()..color = Colors.black,
      );
    final inkPicture = inkRecorder.endRecording();
    final ink = await inkPicture.toImage(360, 128);
    inkPicture.dispose();
    final means = <double>[];
    for (final program in programs) {
      final shader = program.fragmentShader();
      shader.setImageSampler(0, scene);
      shader.setImageSampler(1, ink);
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
        180,
        0,
        1,
        0,
        24,
        24,
        14,
        10,
        .5,
        0,
        0,
        1,
        0,
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
      final outputRecorder = ui.PictureRecorder();
      Canvas(
        outputRecorder,
      ).drawRect(const Rect.fromLTWH(0, 0, 360, 64), Paint()..shader = shader);
      final picture = outputRecorder.endRecording();
      final image = await picture.toImage(360, 64);
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
      expect(data[3], 0);
      var total = 0;
      for (var y = 28; y < 36; y++) {
        for (var x = 145; x < 151; x++) {
          final offset = (y * 360 + x) * 4;
          total += data[offset];
          expect(data[offset + 3], 255);
        }
      }
      means.add(total / 48);
      final verification = Directory('build/verification')
        ..createSync(recursive: true);
      File('${verification.path}/neutral-${means.length}.png').writeAsBytesSync(
        (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List(),
      );
      image.dispose();
      picture.dispose();
      shader.dispose();
    }
    expect(
      (means[0] - 128).abs() - (means[1] - 128).abs(),
      greaterThan(5),
      reason:
          'Refined neutral transmission must stay closer to the sampled source',
    );
    scene.dispose();
    ink.dispose();
  });
}
