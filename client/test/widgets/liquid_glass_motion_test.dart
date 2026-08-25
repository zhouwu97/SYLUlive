import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/liquid_glass/bottom_nav_controller.dart';
import 'package:shenliyuan/widgets/liquid_glass/liquid_glass_motion.dart';
import 'package:shenliyuan/widgets/liquid_glass/liquid_glass_runtime.dart';

void main() {
  test('Dock 常驻 Lens，Selection 只在交互阶段提升折射与色散', () {
    const tuning = LiquidGlassTuning();
    final idle = liquidGlassMotionFor(
      phase: LiquidNavPhase.idle,
      activation: 0,
      velocityPixelsPerSecond: 0,
      visualPosition: 1,
      currentIndex: 1,
      edgeCompression: 0,
      reduceMotion: false,
      tuning: tuning,
    );
    final pressing = liquidGlassMotionFor(
      phase: LiquidNavPhase.pressing,
      activation: 1,
      velocityPixelsPerSecond: 0,
      visualPosition: 1,
      currentIndex: 1,
      edgeCompression: 0,
      reduceMotion: false,
      tuning: tuning,
    );
    final dragging = liquidGlassMotionFor(
      phase: LiquidNavPhase.dragging,
      activation: 1,
      velocityPixelsPerSecond: 900,
      visualPosition: 1.4,
      currentIndex: 1,
      edgeCompression: 0,
      reduceMotion: false,
      tuning: tuning,
    );

    expect(idle.opticalActivation, closeTo(0.0, 0.0001));
    expect(idle.dockOpticalActivation, closeTo(1.0, 0.0001));
    expect(idle.highlightProgress, closeTo(0.0, 0.0001));
    expect(pressing.highlightProgress, greaterThan(0));
    expect(dragging.highlightProgress, closeTo(1.0, 0.0001));
    expect(idle.refraction, lessThan(pressing.refraction));
    expect(pressing.refraction, lessThan(dragging.refraction));
    expect(idle.chromatic, lessThan(pressing.chromatic));
    expect(pressing.chromatic, lessThan(dragging.chromatic));
    expect(dragging.dockRecoilX, greaterThan(0));
    expect(dragging.dockChromatic, closeTo(0.0, 0.0001));
  });

  test('reduced motion 仍保留材质状态，但移除速度与 Dock recoil', () {
    const tuning = LiquidGlassTuning();
    final reduced = liquidGlassMotionFor(
      phase: LiquidNavPhase.dragging,
      activation: 1,
      velocityPixelsPerSecond: 1200,
      visualPosition: 2,
      currentIndex: 1,
      edgeCompression: 0.4,
      reduceMotion: true,
      tuning: tuning,
    );

    expect(reduced.opticalActivation, 1);
    expect(reduced.speed, 0);
    expect(reduced.direction, 0);
    expect(reduced.dockRecoilX, 0);
  });

  test('拖拽形变左右对称，边界压缩也会继续拉伸 Lens', () {
    final right = liquidGlassDragDeformationFor(
      velocityPixelsPerSecond: 900,
      normalization: 1000,
    );
    final left = liquidGlassDragDeformationFor(
      velocityPixelsPerSecond: -900,
      normalization: 1000,
    );
    final edgePull = liquidGlassDragDeformationFor(
      velocityPixelsPerSecond: 0,
      normalization: 1000,
      edgeCompression: 1,
    );

    expect(right.direction, 1);
    expect(left.direction, -1);
    expect(right.intensity, closeTo(left.intensity, 0.0001));
    expect(right.horizontalScale, closeTo(left.horizontalScale, 0.0001));
    expect(right.verticalScale, closeTo(left.verticalScale, 0.0001));
    expect(edgePull.horizontalScale, greaterThan(1));
    expect(edgePull.verticalScale, lessThan(1));
  });

  test(
      'Dock shader uniform layout and three-channel shader contract are stable',
      () {
    const uniforms = LiquidGlassDockShaderUniforms(
      logicalSize: Size(336, 64),
      dockSize: Size(336, 64),
      refraction: 24,
      chromatic: 0.0,
      refractionHeight: 24,
      activation: 1.0,
    );

    expect(uniforms.values, hasLength(10));
    expect(uniforms.values[0].isNaN, isTrue);
    expect(uniforms.values[1].isNaN, isTrue);
    expect(uniforms.values[LiquidGlassDockShaderUniforms.logicalSizeX], 336);
    expect(uniforms.values[LiquidGlassDockShaderUniforms.refractionIndex], -24);
    expect(uniforms.values[LiquidGlassDockShaderUniforms.activationIndex], 1.0);

    final source = File('shaders/liquid_nav_dock.frag').readAsStringSync();
    expect(source, contains('uniform vec2 uDockSize'));
    expect(source, contains('uniform float uRefractionHeight'));
    expect(source, contains('vec4 red'));
    expect(source, contains('vec4 green'));
    expect(source, contains('vec4 blue'));
    expect(source, contains('smoothstep'));
  });

}
