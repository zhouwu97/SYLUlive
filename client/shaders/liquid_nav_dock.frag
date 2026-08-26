#version 460 core

#include <flutter/runtime_effect.glsl>

// Dock 只使用三通道边缘采样；selection Lens 保留七通道色散。
// 这是基于 Apache-2.0 AndroidLiquidGlass 思路的独立 Flutter/GLSL 实现。
uniform vec2 uInputSize;
uniform vec2 uLogicalSize;
uniform vec2 uDockSize;
uniform float uRefraction;
uniform float uChromatic;
uniform float uRefractionHeight;
uniform float uActivation;
uniform sampler2D uBackdrop;

out vec4 fragColor;

float sdRoundedRect(vec2 coord, vec2 halfSize, float radius) {
  vec2 cornerCoord = abs(coord) - (halfSize - vec2(radius));
  float outside = length(max(cornerCoord, 0.0)) - radius;
  float inside = min(max(cornerCoord.x, cornerCoord.y), 0.0);
  return outside + inside;
}

vec2 gradSdRoundedRect(vec2 coord, vec2 halfSize, float radius) {
  vec2 cornerCoord = abs(coord) - (halfSize - vec2(radius));
  vec2 signCoord = sign(coord);
  if (cornerCoord.x >= 0.0 || cornerCoord.y >= 0.0) {
    vec2 outside = max(cornerCoord, 0.0);
    float outsideLength = length(outside);
    if (outsideLength > 0.0001) {
      return signCoord * (outside / outsideLength);
    }
  }
  float gradX = step(cornerCoord.y, cornerCoord.x);
  return signCoord * vec2(gradX, 1.0 - gradX);
}

// 与 selection Lens 共用的圆弧截面映射。相比线性的 smoothstep，边缘带
// 会更像凸透镜：靠近表面时位移快速建立，向中心收拢时自然归零。
float circleMap(float x) {
  float clamped = clamp(x, 0.0, 1.0);
  return 1.0 - sqrt(max(0.0, 1.0 - clamped * clamped));
}

vec2 logicalFragCoord() {
  return FlutterFragCoord().xy *
      (uLogicalSize / max(uInputSize, vec2(0.001)));
}

vec2 textureUv(vec2 logicalPixel) {
  vec2 uv = clamp(
      logicalPixel / max(uLogicalSize, vec2(0.001)),
      vec2(0.0),
      vec2(1.0)
  );
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return uv;
}

void main() {
  vec2 coord = logicalFragCoord();
  vec4 original = texture(uBackdrop, textureUv(coord));
  float activation = clamp(uActivation, 0.0, 1.0);
  float edgeHeight = max(uRefractionHeight, 0.0001);
  if (activation <= 0.0001 || edgeHeight <= 0.0001) {
    fragColor = original;
    return;
  }

  vec2 halfSize = uDockSize * 0.5;
  vec2 centeredCoord = coord - halfSize;
  float radius = min(halfSize.x, halfSize.y);
  float sd = sdRoundedRect(centeredCoord, halfSize, radius);
  float edgeDepth = clamp(-sd, 0.0, edgeHeight);
  if (edgeDepth >= edgeHeight) {
    // 中央区域不需要法线或额外采样，避免 rounded-rect 中心的零向量
    // normalize 产生未定义坐标。
    fragColor = original;
    return;
  }
  float edgePosition = 1.0 - clamp(edgeDepth / edgeHeight, 0.0, 1.0);
  float edgeProfile = circleMap(edgePosition);
  vec2 normal = normalize(gradSdRoundedRect(centeredCoord, halfSize, radius));
  float displacement = edgeProfile * uRefraction;
  vec2 refractedCoord = coord + normal * displacement;

  // 色散只留在 Dock 的折射带，中心保持原色，避免大面积彩虹噪声。
  // 当 QA 切到 chromatic-only 时，uRefraction 为 0；保留半个边缘高度
  // 作为色散基准距离，确保该模式仍能独立观察 RGB 分离。
  float chromaticBase = max(abs(displacement), edgeHeight * 0.5);
  vec2 dispersion = normal * chromaticBase * uChromatic * edgeProfile;
  vec4 red = texture(uBackdrop, textureUv(refractedCoord + dispersion));
  vec4 green = texture(uBackdrop, textureUv(refractedCoord));
  vec4 blue = texture(uBackdrop, textureUv(refractedCoord - dispersion));
  vec3 refracted = vec3(red.r, green.g, blue.b);
  vec3 color = mix(original.rgb, refracted, activation * edgeProfile);
  fragColor = vec4(color, original.a);
}
