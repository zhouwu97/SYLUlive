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

float liquidDistance(vec2 point) {
  vec2 center = uSize * 0.5;
  vec2 halfSize = uSize * 0.5;
  vec2 normalized = (point - center) / max(halfSize, vec2(0.001));

  // Superellipse 让静止态保持柔和的胶囊感；运动时通过方向项让
  // 迎风侧鼓起、尾侧拉长。Flutter ClipPath 会提供最终的可见边界，
  // 这里保持同一组速度/方向参数，使折射边缘与外轮廓一致。
  normalized.x -= uDirection * uVelocity * 0.055;
  float exponent = mix(4.6, 3.0, uVelocity);
  float body = pow(
      pow(abs(normalized.x), exponent) +
          pow(abs(normalized.y), exponent),
      1.0 / exponent) - 1.0;
  float rearCompression = max(-uDirection * normalized.x, 0.0) *
      uEdgeCompression * 0.16;
  return (body + rearCompression) * min(halfSize.x, halfSize.y);
}

vec2 liquidNormal(vec2 point) {
  const float epsilon = 0.45;
  float dx = liquidDistance(point + vec2(epsilon, 0.0)) -
      liquidDistance(point - vec2(epsilon, 0.0));
  float dy = liquidDistance(point + vec2(0.0, epsilon)) -
      liquidDistance(point - vec2(0.0, epsilon));
  return normalize(vec2(dx, dy) + vec2(0.0001));
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
  float distanceToLens = liquidDistance(fragment);

  if (distanceToLens > 1.0) {
    fragColor = texture(uBackdrop, textureUv(fragment));
    return;
  }

  vec2 normal = liquidNormal(fragment);
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
