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
      refractionHeight: 12.0,
      refraction: 16,
      chromatic: 1.0,
      activation: 1,
    );

    expect(uniforms.values, hasLength(12));
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
    expect(uniforms.values[LiquidGlassShaderUniforms.refractionIndex], -16);
    expect(
      uniforms.values[LiquidGlassShaderUniforms.activationIndex],
      1,
    );
    expect(
      uniforms.values[LiquidGlassShaderUniforms.refractionHeightIndex],
      12.0,
    );
  });

  test('V9 shader keeps the reference edge model and seven samples', () {
    final source = File('shaders/liquid_nav_lens.frag').readAsStringSync();

    expect(source, contains('float circleMap(float x)'));
    expect(source, contains('uniform vec2 uInputSize'));
    expect(source, contains('uniform vec2 uLogicalSize'));
    expect(source, contains('vec2 logicalFragCoord()'));
    expect(source, contains('float gradRadius = min(radius * 1.5'));
    expect(source, contains('if (-sd >= refractionHeight)'));
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
    expect(source, contains('uRefractionHeight'));
    expect(source, contains('dispersionIntensity = uChromatic'));
    expect(source, isNot(contains('chromaticStart')));
    final highlightSource =
        File('shaders/liquid_nav_highlight.frag').readAsStringSync();
    expect(highlightSource, contains('dot(grad, normal)'));
    expect(highlightSource, contains('uFalloff'));
    final bottomNavSource =
        File('lib/widgets/bottom_nav.dart').readAsStringSync();
    expect(bottomNavSource, contains('const _scaleXSpring'));
    expect(bottomNavSource, contains('const _scaleYSpring'));
    expect(bottomNavSource, isNot(contains('liquidGlassSurfacePositionFor')));
    final pointerSource =
        File('lib/widgets/liquid_glass/interactive_highlight.dart')
            .readAsStringSync();
    expect(pointerSource, contains('0.08'));
    expect(pointerSource, contains('0.15'));
    expect(pointerSource, contains('BlendMode.plus'));
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
    expect(chromatic.effectiveRefractionHeight, greaterThan(0));
    expect(chromatic.effectiveDockRefraction, 0);
    expect(chromatic.effectiveDockChromatic, greaterThan(0));

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
    expect(tuning.refractionHeight, 16);
    expect(tuning.refraction, 22.0);
    expect(tuning.chromatic, 1.15);
    expect(tuning.rimStrength, 0.20);
    expect(tuning.lightStrength, 0.36);
    expect(tuning.effectiveMagnification, 1);
    expect(tuning.dockAlpha, 0.12);
    expect(tuning.dockBlur, 8.0);
    expect(tuning.idleOpticalActivation, 0.38);
    expect(tuning.dockRefraction, 28.0);
    expect(tuning.dockChromatic, 0.16);
    expect(tuning.dockRefractionHeight, 26.0);
    expect(tuning.dockSaturation, 1.06);
    expect(tuning.dockContrast, 1.02);
    expect(tuning.dockLensHeight, 24.0);
    expect(tuning.dockLensAmount, 24.0);
    expect(tuning.lensSurfaceAlpha, 0.08);
    expect(tuning.lensPressedSurfaceAlpha, 0.035);
  });

  test('Old v1 preset freezes the 57ca812 visual contract', () {
    const tuning = LiquidGlassTuning.oldV1;

    expect(tuning.isOldV1, isTrue);
    expect(tuning.lensHeight, 58.0);
    expect(tuning.pressedScale, 1.0);
    expect(tuning.magnification, 0.85);
    expect(tuning.chromatic, 0.075);
    expect(tuning.dockBlur, 16.0);
    expect(tuning.idleOpticalActivation, 1.0);

    const uniforms = LiquidGlassOldV1ShaderUniforms(
      center: Offset(0.5, 0.75),
      halfSize: Size(0.12, 0.04),
      refraction: 0.02,
      zoom: 0.85,
      chromatic: 0.075,
      motion: 0.5,
      direction: -1,
      tint: Color(0x33147C72),
    );
    expect(uniforms.values, hasLength(15));
    expect(uniforms.values[LiquidGlassOldV1ShaderUniforms.zoomIndex], 0.85);
    expect(
      uniforms.values[LiquidGlassOldV1ShaderUniforms.directionIndex],
      -1,
    );
  });

  test('Old v1 shader and QA A/B controls are registered', () {
    final shaderSource =
        File('shaders/liquid_nav_lens_v1.frag').readAsStringSync();
    final qaSource = File(
      'lib/widgets/liquid_glass/liquid_glass_qa_screen.dart',
    ).readAsStringSync();

    expect(shaderSource, contains('float capsuleDistance'));
    expect(shaderSource, contains('uZoom'));
    expect(shaderSource, contains('uChromatic'));
    expect(qaSource, contains('旧版 v1 · 57ca812'));
    expect(qaSource, contains('当前 · HEAD'));
  });

  test('V9 Reference QA exposes a white Color Composite contract', () {
    final source = File(
      'lib/widgets/liquid_glass/liquid_glass_qa_screen.dart',
    ).readAsStringSync();
    expect(source, contains('liquid-glass-reference-background'));
    expect(source, contains('color: Colors.white'));
    expect(source, contains('普通导航行全部保持中性'));
  });

  test(
      'Optical QA uses high-contrast probes and exposes isolated material modes',
      () {
    final source = File(
      'lib/widgets/liquid_glass/liquid_glass_qa_screen.dart',
    ).readAsStringSync();
    expect(source, contains('LiquidGlassQaPattern.optical'));
    expect(source, contains('Color(0xFFF28C28)'));
    expect(source, contains('Color(0xFF21A366)'));
    expect(source, contains('Color(0xFF1976D2)'));
    expect(source, contains('仅模糊'));
    expect(source, contains('仅色散'));
    expect(source, contains('仅高光'));
    expect(source, contains('最终玻璃'));
  });
}
