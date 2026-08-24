#version 460 core

#include <flutter/runtime_effect.glsl>

// V8 shader port of AndroidLiquidGlass BottomTabs.
//
// 光学模型刻意保持克制：Capsule 中央直接返回原图，只有靠近边缘的一圈
// 使用 Rounded-Rect SDF 法线做折射；色散沿同一折射方向错开采样。
uniform vec2 uSize;
uniform vec2 uLensCenter;
uniform vec2 uLensHalfSize;
uniform float uLensExponent; // 旧 uniform，保留布局兼容；V8 不再使用。
uniform float uRefraction;
uniform float uMagnification; // 旧 uniform；中心 magnification 已移除。
uniform float uChromatic;
uniform float uVelocity;
uniform float uDirection;
uniform float uEdgeCompression;
uniform float uDragState;
uniform vec4 uTint;
uniform float uLightStrength;
uniform float uRimStrength;
uniform float uVerticalRefractionScale;
uniform float uRefractionBandStart;
uniform float uRefractionBandPeak;
uniform float uRefractionBandEnd;
uniform float uMagnificationRadius;
uniform float uChromaticStart;
uniform float uFlowStrength;
uniform float uActivation;
uniform float uPressDepth;
uniform sampler2D uBackdrop;

out vec4 fragColor;

struct CapsuleState {
  float signedDistance;
  vec2 normal;
};

// iq rounded-box SDF。Capsule 是 radius = halfHeight 的特例。
float roundedRectSdf(vec2 point, vec2 halfSize, float radius) {
  vec2 q = abs(point) - (halfSize - vec2(radius));
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

vec2 roundedRectNormal(vec2 point, vec2 halfSize, float radius) {
  vec2 q = abs(point) - (halfSize - vec2(radius));
  vec2 outside = max(q, 0.0);
  float outsideLength = length(outside);
  vec2 signPoint = vec2(
      point.x < 0.0 ? -1.0 : 1.0,
      point.y < 0.0 ? -1.0 : 1.0
  );

  if (outsideLength > 0.0001) {
    return normalize(outside) * signPoint;
  }

  // Capsule 中心段的法线只在 edge band 内才会被使用；选最近侧即可。
  if (q.x > q.y) return vec2(signPoint.x, 0.0);
  return vec2(0.0, signPoint.y);
}

CapsuleState capsuleState(vec2 fragment) {
  vec2 local = fragment - uLensCenter;
  float radius = min(uLensHalfSize.y, uLensHalfSize.x);
  float signedDistance = roundedRectSdf(local, uLensHalfSize, radius);
  vec2 normal = roundedRectNormal(local, uLensHalfSize, radius);
  return CapsuleState(signedDistance, normal);
}

vec2 textureUv(vec2 pixel) {
  vec2 uv = clamp(pixel / max(uSize, vec2(0.001)), vec2(0.0), vec2(1.0));
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return uv;
}

void main() {
  vec2 fragment = FlutterFragCoord().xy;
  vec4 original = texture(uBackdrop, textureUv(fragment));
  float activation = clamp(uActivation, 0.0, 1.0);

  if (activation <= 0.0001) {
    fragColor = original;
    return;
  }

  CapsuleState state = capsuleState(fragment);
  float aa = max(fwidth(state.signedDistance), 0.0005);
  float capsuleMask = 1.0 - smoothstep(
      0.0,
      aa,
      state.signedDistance
  );

  // 10dp 左右的 edge band 随 pressProgress 生长；中心区域不做采样位移。
  float edgeBand = max(
      0.5,
      uLensHalfSize.y * uRefractionBandPeak * 0.45 * activation
  );
  float edgeMask = (1.0 - smoothstep(
      0.0,
      edgeBand,
      max(-state.signedDistance, 0.0)
  )) * capsuleMask;

  vec2 opticalNormal = normalize(vec2(
      state.normal.x,
      state.normal.y * max(uVerticalRefractionScale, 0.08)
  ));
  float refraction = uRefraction * activation;
  float chromatic = uChromatic * activation;
  vec2 samplePixel = fragment - opticalNormal * refraction * edgeMask;
  vec2 chromaticOffset = opticalNormal * chromatic * edgeMask;

  // 色散是同一折射方向上的多通道错位，不额外绘制彩虹边框。
  vec3 refracted = vec3(
      texture(uBackdrop, textureUv(samplePixel - chromaticOffset)).r,
      texture(uBackdrop, textureUv(samplePixel)).g,
      texture(uBackdrop, textureUv(samplePixel + chromaticOffset)).b
  );
  vec3 color = mix(original.rgb, refracted, edgeMask);

  float lightStrength = uLightStrength * activation;
  float rimStrength = uRimStrength * activation;
  float facing = max(dot(opticalNormal, normalize(vec2(-0.72, -0.70))), 0.0);
  float specular = pow(facing, 4.0) * edgeMask;
  color += vec3(specular * lightStrength * 1.10);

  vec3 dispersionTint = mix(
      vec3(0.54, 0.76, 1.0),
      vec3(1.0, 0.70, 0.36),
      clamp(opticalNormal.x * 0.5 + 0.5, 0.0, 1.0)
  );
  color += dispersionTint * rimStrength * edgeMask * 0.78;
  color += dispersionTint * uDragState * 0.018 * edgeMask * activation;

  // 保留很轻的按压质量感，不用白色覆盖伪造玻璃。
  color += vec3(0.035, 0.018, -0.004) * uPressDepth * edgeMask;
  color = mix(color, uTint.rgb, uTint.a * edgeMask);

  fragColor = vec4(clamp(color, 0.0, 1.0), original.a);
}
