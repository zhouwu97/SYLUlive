import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/bottom_nav.dart';
import 'package:shenliyuan/widgets/liquid_glass/liquid_glass_runtime.dart';

void main() {
  test('V9 tuning keeps optical samples inside the overscan budget', () {
    const tuning = LiquidGlassTuning();
    const lensWidth = 104.0;
    const lensHeight = 62.0;

    expect(
      tuning.overscanXFor(lensWidth),
      greaterThan(tuning.maxSampleOffsetXFor(lensWidth)),
    );
    expect(
      tuning.overscanYFor(lensHeight),
      greaterThan(tuning.maxSampleOffsetYFor(lensHeight)),
    );
  });

  test('V9 shader uniform layout is stable and named', () {
    const uniforms = LiquidGlassShaderUniforms(
      captureSize: Size(160, 94),
      lensCenter: Offset(80, 47),
      lensSize: Size(104, 62),
      lensExponent: 2.15,
      refraction: 16,
      magnification: 1.0,
      chromatic: 0.95,
      velocity: 0,
      direction: 0,
      edgeCompression: 0,
      dragState: 0,
      lightStrength: 0.18,
      rimStrength: 0.1,
      verticalRefractionScale: 0.32,
      refractionBandStart: 0.6,
      refractionBandPeak: 10.0,
      refractionBandEnd: 0.92,
      magnificationRadius: 0.66,
      chromaticStart: 0.84,
      flowStrength: 0.72,
      activation: 1,
      pressDepth: 0,
    );

    expect(uniforms.values, hasLength(31));
    expect(LiquidGlassShaderUniforms.customUniformStart, 2);
    expect(
      uniforms.values[LiquidGlassShaderUniforms.engineInputWidth].isNaN,
      isTrue,
    );
    expect(
      uniforms.values[LiquidGlassShaderUniforms.engineInputHeight].isNaN,
      isTrue,
    );
    expect(uniforms.values[LiquidGlassShaderUniforms.logicalSizeX], 160);
    expect(uniforms.values[LiquidGlassShaderUniforms.lensCenterX], 80);
    expect(
      uniforms.values[LiquidGlassShaderUniforms.lensHalfWidth],
      52,
    );
    expect(
      uniforms.values[LiquidGlassShaderUniforms.flowStrengthIndex],
      0.72,
    );
    expect(
      uniforms.values[LiquidGlassShaderUniforms.activationIndex],
      1,
    );
  });

  test('V9 shader keeps the reference edge model and seven samples', () {
    final source = File('shaders/liquid_nav_lens.frag').readAsStringSync();

    expect(source, contains('float circleMap(float x)'));
    expect(source, contains('uniform vec2 uInputSize'));
    expect(source, contains('uniform vec2 uLogicalSize'));
    expect(source, contains('vec2 logicalFragCoord()'));
    expect(source, contains('float gradRadius = min(radius * 1.5'));
    expect(source, contains('uRefractionBandPeak'));
    for (final channel in const [
      'vec4 red',
      'vec4 orange',
      'vec4 yellow',
      'vec4 green',
      'vec4 cyan',
      'vec4 blue',
      'vec4 purple',
    ]) {
      expect(source, contains(channel));
    }
    expect(source, contains('smoothstep'));
    expect(source, contains('chromaticBandWidth'));
    expect(source, isNot(contains('dispersionTint')));
  });

  test('V9 QA modes isolate edge refraction, chromatic and Fresnel', () {
    const core = LiquidGlassTuning(
      mode: LiquidGlassQaMode.coreOnly,
    );
    expect(core.effectiveMagnification, 1);
    expect(core.effectiveRefraction, 0);

    const refraction = LiquidGlassTuning(
      mode: LiquidGlassQaMode.refractionOnly,
    );
    expect(refraction.effectiveRefraction, greaterThan(0));
    expect(refraction.effectiveMagnification, 1);
    expect(refraction.effectiveChromatic, 0);

    const chromatic = LiquidGlassTuning(
      mode: LiquidGlassQaMode.chromaticOnly,
    );
    expect(chromatic.effectiveChromatic, greaterThan(0));
    expect(chromatic.effectiveRefraction, 0);

    const fresnel = LiquidGlassTuning(
      mode: LiquidGlassQaMode.fresnelOnly,
    );
    expect(fresnel.effectiveLightStrength, greaterThan(0));
    expect(fresnel.effectiveRimStrength, greaterThan(0));
  });

  test('V9 Capsule geometry stays bounded and mirrored', () {
    const size = Size(108, 62);
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

    expect(right.getBounds().left, greaterThanOrEqualTo(0));
    expect(right.getBounds().right, lessThanOrEqualTo(size.width));
    expect(right.getBounds().top, closeTo(0, 0.001));
    expect(right.getBounds().bottom, closeTo(size.height, 0.001));
    expect(right.computeMetrics().length,
        closeTo(left.computeMetrics().length, 0.01));
    expect(right.computeMetrics().length, greaterThan(0));
  });

  test('V9 selection window helper remains continuous across adjacent tabs',
      () {
    expect(
      liquidNavFocusWeight(
        currentIndex: 0,
        index: 0,
        visualPosition: 0,
        activation: 0,
      ),
      1,
    );
    expect(
      liquidNavFocusWeight(
        currentIndex: 0,
        index: 1,
        visualPosition: 0,
        activation: 0,
      ),
      0,
    );
    expect(
      liquidNavFocusWeight(
        currentIndex: 0,
        index: 0,
        visualPosition: 0.5,
        activation: 1,
      ),
      closeTo(0.5, 0.001),
    );
    expect(
      liquidNavFocusWeight(
        currentIndex: 0,
        index: 1,
        visualPosition: 0.5,
        activation: 1,
      ),
      closeTo(0.5, 0.001),
    );
  });

  test('V9 reference parameters keep explicit edge and Dock glass values', () {
    const tuning = LiquidGlassTuning();

    expect(tuning.lensHeight, 56);
    expect(tuning.pressedScale, closeTo(78 / 56, 0.0001));
    expect(tuning.refractionHeight, 8);
    expect(tuning.refraction, 7.2);
    expect(tuning.chromatic, 0.14);
    expect(tuning.effectiveMagnification, 1);
    expect(tuning.dockAlpha, 0.20);
    expect(tuning.dockBlur, 8.0);
    expect(tuning.dockLensHeight, 24.0);
    expect(tuning.dockLensAmount, 24.0);
  });

  test('V9 Reference QA exposes a white Color Composite contract', () {
    final source = File(
      'lib/widgets/liquid_glass/liquid_glass_qa_screen.dart',
    ).readAsStringSync();
    expect(source, contains('liquid-glass-reference-background'));
    expect(source, contains('color: Colors.white'));
    expect(source, contains('Normal Row 全部 neutral'));
  });
}
