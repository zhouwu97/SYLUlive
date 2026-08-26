#version 460 core

#include <flutter/runtime_effect.glsl>

// Kyant AndroidLiquidGlass RoundedRectRefraction 的 Flutter Runtime Shader
// 移植。Flutter 负责 uInputSize/uBackdrop；其余坐标统一使用 logical px。
uniform vec2 uInputSize;
uniform vec2 uLogicalSize;
uniform vec2 uLensCenter;
uniform vec2 uLensHalfSize;
uniform float uRefractionHeight;
uniform float uRefraction;
uniform float uChromatic;
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
  float refractionHeight = max(uRefractionHeight, 0.0001);

  if (activation <= 0.0001 || refractionHeight <= 0.0001) {
    fragColor = original;
    return;
  }

  vec2 halfSize = uLensHalfSize;
  vec2 centeredCoord = coord - uLensCenter;
  float radius = min(halfSize.x, halfSize.y);
  float sd = sdRoundedRect(centeredCoord, halfSize, radius);
  if (sd > 0.0) {
    fragColor = original;
    return;
  }

  if (-sd >= refractionHeight) {
    fragColor = original;
    return;
  }
  sd = min(sd, 0.0);

  // refraction 是由 Flutter 按 Kyant 的 Lens.kt 语义传入的负值。
  float d = circleMap(1.0 - (-sd / refractionHeight)) * uRefraction;
  float gradRadius = min(radius * 1.5, min(halfSize.x, halfSize.y));
  vec2 grad = normalize(gradSdRoundedRect(centeredCoord, halfSize, gradRadius));
  vec2 refractedCoord = coord + d * grad;

  // Kyant 的七通道色散作用于整个折射区域，不再裁成最外缘的一条彩边。
  float dispersionIntensity = uChromatic *
      ((centeredCoord.x * centeredCoord.y) /
      max(halfSize.x * halfSize.y, 0.0001));
  // chromatic-only QA 需要在没有几何位移时仍能看到 RGB 分离；使用半个
  // 光学边缘高度作为最低色散基准，生产态的最大跨度仍由 d 控制。
  float chromaticSign = d < -0.0001 ? -1.0 : 1.0;
  float dispersionDistance =
      max(abs(d), refractionHeight * 0.5) * chromaticSign;
  vec2 dispersedCoord = dispersionDistance * grad * dispersionIntensity;
  vec4 color = vec4(0.0);

  vec4 red = texture(uBackdrop, textureUv(refractedCoord + dispersedCoord));
  color.r += red.r / 3.5;
  color.a += red.a / 7.0;

  vec4 orange = texture(
      uBackdrop,
      textureUv(refractedCoord + dispersedCoord * (2.0 / 3.0))
  );
  color.r += orange.r / 3.5;
  color.g += orange.g / 7.0;
  color.a += orange.a / 7.0;

  vec4 yellow = texture(
      uBackdrop,
      textureUv(refractedCoord + dispersedCoord * (1.0 / 3.0))
  );
  color.r += yellow.r / 3.5;
  color.g += yellow.g / 3.5;
  color.a += yellow.a / 7.0;

  vec4 green = texture(uBackdrop, textureUv(refractedCoord));
  color.g += green.g / 3.5;
  color.a += green.a / 7.0;

  vec4 cyan = texture(
      uBackdrop,
      textureUv(refractedCoord - dispersedCoord * (1.0 / 3.0))
  );
  color.g += cyan.g / 3.5;
  color.b += cyan.b / 3.0;
  color.a += cyan.a / 7.0;

  vec4 blue = texture(
      uBackdrop,
      textureUv(refractedCoord - dispersedCoord * (2.0 / 3.0))
  );
  color.b += blue.b / 3.0;
  color.a += blue.a / 7.0;

  vec4 purple = texture(
      uBackdrop,
      textureUv(refractedCoord - dispersedCoord)
  );
  color.r += purple.r / 7.0;
  color.b += purple.b / 3.0;
  color.a += purple.a / 7.0;

  fragColor = color;
}
