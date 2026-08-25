#version 460 core

#include <flutter/runtime_effect.glsl>

// 57ca812 的首版 Liquid Selection Lens。
//
// 这条路径只用于 QA A/B：中心轻微 zoom、Capsule 边缘法线折射、少量
// chromatic offset，以及左上高光/右下阴影共同建立玻璃厚度。
uniform vec2 uSize;
uniform vec2 uCenter;
uniform vec2 uHalfSize;
uniform float uRefraction;
uniform float uZoom;
uniform float uChromatic;
uniform float uMotion;
uniform float uDirection;
uniform vec4 uTint;
uniform sampler2D uBackdrop;

out vec4 fragColor;

float capsuleDistance(vec2 point, vec2 center, vec2 halfSize) {
  vec2 local = point - center;
  float straightHalf = max(halfSize.x - halfSize.y, 0.0);
  local.x -= clamp(local.x, -straightHalf, straightHalf);
  return length(local) - halfSize.y;
}

vec2 capsuleNormal(vec2 point, vec2 center, vec2 halfSize) {
  vec2 local = point - center;
  float straightHalf = max(halfSize.x - halfSize.y, 0.0);
  local.x -= clamp(local.x, -straightHalf, straightHalf);
  return normalize(local + vec2(0.0001));
}

vec2 textureUv(vec2 pixel) {
  vec2 uv = clamp(pixel / uSize, vec2(0.0), vec2(1.0));
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return uv;
}

void main() {
  vec2 fragment = FlutterFragCoord().xy;
  vec2 center = uCenter * uSize;
  vec2 halfSize = uHalfSize * uSize;
  float distanceToLens = capsuleDistance(fragment, center, halfSize);

  // ClipRRect 之外通常不会执行；这里仍显式透传，避免边缘采样异常。
  if (distanceToLens > 1.0) {
    fragColor = texture(uBackdrop, textureUv(fragment));
    return;
  }

  vec2 normal = capsuleNormal(fragment, center, halfSize);
  float bevel = max(halfSize.y * 0.44, 3.0);
  float rim = smoothstep(-bevel, 0.0, distanceToLens);

  // 中心区域做轻微放大，边缘按法线向内聚拢，形成真实可见的折射带。
  float zoom = 1.0 + uZoom * (1.0 - rim * 0.35);
  vec2 samplePixel = center + (fragment - center) / zoom;
  float refractionPixels = uRefraction * uSize.x;
  samplePixel -= normal * rim * rim * refractionPixels;

  // 移动时让光场略微朝运动方向偏移，但不移动实际内容布局。
  samplePixel.x -= uDirection * uMotion * (1.0 - rim) * 0.8;

  vec2 chromaticOffset = normal * uChromatic;
  vec3 color = vec3(
    texture(uBackdrop, textureUv(samplePixel - chromaticOffset)).r,
    texture(uBackdrop, textureUv(samplePixel)).g,
    texture(uBackdrop, textureUv(samplePixel + chromaticOffset)).b
  );

  float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
  color = mix(vec3(luminance), color, 1.10 + uMotion * 0.05);
  color = mix(color, uTint.rgb, uTint.a);

  // 左上主高光、右下弱阴影与整圈内反射共同建立玻璃厚度。
  vec2 lightDirection = normalize(vec2(-0.72 + uDirection * uMotion * 0.12, -0.70));
  float facingLight = max(dot(normal, lightDirection), 0.0);
  float facingShade = max(dot(normal, -lightDirection), 0.0);
  float specular = pow(facingLight, 5.0) * rim;
  color += vec3(specular * (0.22 + uMotion * 0.08));
  color -= vec3(facingShade * rim * 0.045);
  color += vec3(rim * 0.025);

  fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
