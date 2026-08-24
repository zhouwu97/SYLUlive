#version 460 core

#include <flutter/runtime_effect.glsl>

// ImageFilter.shader 提供的是 Lens 自己这块局部纹理，所有坐标都在
// local pixel space 内计算。不要把屏幕坐标传进来，否则首尾 Tab 会产生
// 不对称折射，横竖屏也会错位。
uniform vec2 uSize;
uniform float uRefraction;
uniform float uMagnification;
uniform float uChromatic;
uniform float uVelocity;
uniform float uDirection;
uniform float uEdgeCompression;
uniform float uDragState;
uniform vec4 uTint;
uniform float uLightStrength;
uniform float uRimStrength;
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
  vec2 center = uSize * 0.5;
  vec2 halfSize = uSize * 0.5;
  float distanceToLens = capsuleDistance(fragment, center, halfSize);

  if (distanceToLens > 1.0) {
    fragColor = texture(uBackdrop, textureUv(fragment));
    return;
  }

  vec2 normal = capsuleNormal(fragment, center, halfSize);
  float bevel = max(halfSize.y * 0.44, 3.0);
  float rim = smoothstep(-bevel, 0.0, distanceToLens);
  float rimSquared = rim * rim;

  // 中心只做轻微放大；折射和 RGB 分离集中在外沿，避免整块 Lens
  // 看起来像彩色故障滤镜。
  float zoom = mix(uMagnification, 1.0, rim * 0.35);
  vec2 samplePixel = center + (fragment - center) / zoom;
  samplePixel -= normal * rimSquared * uRefraction;

  // 真实速度只改变光学场的偏移，不改变 pointer 与 Lens 的位置关系。
  samplePixel.x -= uDirection * uVelocity * (1.0 - rim) * 2.5;
  samplePixel.x -= uDirection * uEdgeCompression * (1.0 - rim) * 4.0;

  vec2 chromaticOffset = normal * uChromatic * rimSquared;
  vec3 color = vec3(
    texture(uBackdrop, textureUv(samplePixel - chromaticOffset)).r,
    texture(uBackdrop, textureUv(samplePixel)).g,
    texture(uBackdrop, textureUv(samplePixel + chromaticOffset)).b
  );

  color = mix(color, uTint.rgb, uTint.a);

  // Fresnel：左上高光、右下暗边、最外沿细亮线。
  vec2 lightDirection = normalize(
    vec2(-0.72 + uDirection * uVelocity * 0.14, -0.70)
  );
  float facingLight = max(dot(normal, lightDirection), 0.0);
  float facingShade = max(dot(normal, -lightDirection), 0.0);
  float specular = pow(facingLight, 5.0) * rim;
  color += vec3(specular * uLightStrength);
  color -= vec3(facingShade * rim * 0.045);
  color += vec3(rim * uRimStrength);

  // 拖动状态略微提高边缘响应，静止时保持克制。
  color += vec3(rimSquared * uDragState * 0.018);
  fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
