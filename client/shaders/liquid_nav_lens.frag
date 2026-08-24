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
  vec2 local = point - center;
  float y = clamp(local.y, -halfSize.y, halfSize.y);
  float cap = sqrt(max(halfSize.y * halfSize.y - y * y, 0.0));
  float straightHalf = max(halfSize.x - halfSize.y, 0.0);
  float profile = 1.0 - smoothstep(
      0.0,
      1.0,
      abs(y) / max(halfSize.y, 0.001)
  );
  float tail = halfSize.y * uVelocity * 0.28;
  float bulge = halfSize.y * uVelocity * 0.18;
  float compression = halfSize.y * uEdgeCompression * 0.16;
  float left = -straightHalf - cap;
  float right = straightHalf + cap;

  // 这组左右边界与 Flutter 的 LiquidLensShape 逐项相同：只画向右
  // canonical 形状，向左交换 tail/bulge 的左右位置，保证严格镜像。
  if (uDirection > 0.01) {
    left -= tail * profile;
    right += bulge * profile - compression * profile;
  } else if (uDirection < -0.01) {
    left -= bulge * profile - compression * profile;
    right += tail * profile;
  }

  float sideDistance = min(local.x - left, right - local.x);
  float verticalDistance = halfSize.y - abs(local.y);
  float insideDistance = min(sideDistance, verticalDistance);
  if (insideDistance >= 0.0) return -insideDistance;

  vec2 outside = vec2(
      max(-sideDistance, 0.0),
      max(-verticalDistance, 0.0)
  );
  return length(outside);
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
  float edgeProximity = 1.0 - smoothstep(
      0.0,
      bevel,
      max(-distanceToLens, 0.0)
  );
  float inner = smoothstep(0.50, 0.88, edgeProximity);
  float outer = 1.0 - smoothstep(0.88, 1.0, edgeProximity);
  float refractBand = inner * outer;
  float rim = smoothstep(0.68, 0.98, edgeProximity);
  float centerProfile = 1.0 - smoothstep(0.40, 0.72, edgeProximity);

  // Magnification 只作用中央区域，Refraction/Chromatic 只作用边缘
  // 内侧的 ring，避免两套位移在整块 Lens 上叠成鱼眼。
  float zoom = mix(1.0, uMagnification, centerProfile);
  vec2 samplePixel = center + (fragment - center) / zoom;
  samplePixel -= normal * refractBand * uRefraction;

  vec2 chromaticOffset = normal * uChromatic * refractBand;
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
  color -= vec3(facingShade * rim * 0.045 * uLightStrength);
  color += vec3(rim * uRimStrength);

  // 拖动状态略微提高边缘响应，静止时保持克制。
  color += vec3(refractBand * uDragState * 0.018);
  fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
