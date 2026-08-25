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
  float edgeFactor = 1.0 - smoothstep(0.0, edgeHeight, edgeDepth);
  vec2 normal = normalize(gradSdRoundedRect(centeredCoord, halfSize, radius));
  float displacement = edgeFactor * uRefraction;
  vec2 refractedCoord = coord + normal * displacement;

  // 色散只留在 Dock 的折射带，中心保持原色，避免大面积彩虹噪声。
  vec2 dispersion = normal * displacement * uChromatic * edgeFactor;
  vec4 red = texture(uBackdrop, textureUv(refractedCoord + dispersion));
  vec4 green = texture(uBackdrop, textureUv(refractedCoord));
  vec4 blue = texture(uBackdrop, textureUv(refractedCoord - dispersion));
  vec3 refracted = vec3(red.r, green.g, blue.b);
  vec3 color = mix(original.rgb, refracted, activation * edgeFactor);
  fragColor = vec4(color, original.a);
}
