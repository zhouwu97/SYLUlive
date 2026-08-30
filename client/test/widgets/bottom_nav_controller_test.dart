import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shenliyuan/widgets/bottom_nav.dart';
import 'package:shenliyuan/widgets/liquid_glass/bottom_nav_controller.dart';
import 'package:shenliyuan/widgets/liquid_glass/liquid_glass_runtime.dart';

void main() {
  test('拖动状态保留连续位置并记录边界压缩', () {
    final controller = BottomNavController(itemCount: 5, initialIndex: 0);

    controller.beginDrag(0);
    controller.updateDrag(
      rawPosition: 1.5,
      velocityPixelsPerSecond: 180,
    );
    expect(controller.position, 1.5);
    expect(controller.edgeCompression, 0);
    expect(controller.velocity, 180);

    controller.updateDrag(
      rawPosition: -0.25,
      velocityPixelsPerSecond: -600,
    );
    expect(controller.position, 0);
    expect(controller.edgeCompression, greaterThan(0));
    expect(controller.velocity, -600);
  });

  test('慢拖吸附最近入口，快速 flick 只推进一格', () {
    final controller = BottomNavController(itemCount: 5, initialIndex: 0);

    controller.beginDrag(0);
    controller.updateDrag(rawPosition: 1.35, velocityPixelsPerSecond: 50);
    expect(
      controller.endDrag(velocityPixelsPerSecond: 50, itemWidth: 67),
      1,
    );

    controller.beginDrag(1);
    controller.updateDrag(rawPosition: 1.2, velocityPixelsPerSecond: 900);
    expect(
      controller.endDrag(velocityPixelsPerSecond: 900, itemWidth: 67),
      2,
    );
  });

  test('V8 QA modes isolate identity, edge refraction and Capsule shape', () {
    const identity = LiquidGlassTuning(mode: LiquidGlassQaMode.identity);
    expect(identity.effectiveRefraction, 0);
    expect(identity.effectiveMagnification, 1);
    expect(identity.effectiveChromatic, 0);
    expect(identity.effectiveLightStrength, 0);
    expect(identity.effectiveRimStrength, 0);

    const refraction =
        LiquidGlassTuning(mode: LiquidGlassQaMode.refractionOnly);
    expect(refraction.effectiveRefraction, greaterThan(0));
    expect(refraction.effectiveMagnification, 1);
    expect(refraction.effectiveChromatic, 0);

    const shape = LiquidGlassTuning(mode: LiquidGlassQaMode.shapeOnly);
    expect(shape.isIdentityLike, isTrue);
  });

  test('Capsule geometry mirrors on X and keeps stable bounds', () {
    const size = Size(108, 56);
    final right = LiquidLensShape.pathForSize(
      size,
      speed: 0.85,
      direction: 1,
      edgeCompression: 0.2,
    );
    final left = LiquidLensShape.pathForSize(
      size,
      speed: 0.85,
      direction: -1,
      edgeCompression: 0.2,
    );

    expect(right.getBounds().top, 0);
    expect(right.getBounds().bottom, 56);
    expect(left.getBounds().top, 0);
    expect(left.getBounds().bottom, 56);
    expect(
      right.computeMetrics().length,
      closeTo(left.computeMetrics().length, 0.001),
    );
  });
}
