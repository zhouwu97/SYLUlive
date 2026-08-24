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

const float SUPERELLIPSE_EXPONENT = 2.5;

struct LiquidState {
  float q;
  vec2 gradient;
};

float smoothProfile(float value) {
  float t = clamp(value, 0.0, 1.0);
  return 1.0 - t * t * (3.0 - 2.0 * t);
}

LiquidState liquidState(vec2 point) {
  vec2 local = point - uSize * 0.5;
  float directionSign = uDirection < -0.01 ? -1.0 : 1.0;
  float canonicalX = local.x * directionSign;
  float halfHeight = max(uSize.y * 0.5, 0.001);
  float tail = halfHeight * uVelocity * 0.50;
  float bulge = halfHeight * uVelocity * 0.26;
  float compression = halfHeight * uEdgeCompression * 0.16;
  float halfWidth = max(
      (uSize.x - tail - bulge + compression) * 0.5,
      halfHeight * 0.72
  );
  float normalizedY = clamp(abs(local.y) / halfHeight, 0.0, 1.0);
  float exponent = SUPERELLIPSE_EXPONENT;
  float yPower = pow(normalizedY, exponent);
  float baseFactor = pow(max(1.0 - yPower, 0.0001), 1.0 / exponent);
  float baseExtent = halfWidth * baseFactor;
  float profile = smoothProfile(normalizedY);

  float leftExtent = baseExtent + tail * profile;
  float rightExtent = baseExtent + (bulge - compression) * profile;
  float centerShift = (rightExtent - leftExtent) * 0.5;
  float halfExtent = max((leftExtent + rightExtent) * 0.5, 0.001);
  float centeredX = canonicalX - centerShift;
  float normalizedX = centeredX / halfExtent;
  float q = pow(abs(normalizedX), exponent) + yPower;

  // 对同一个 superellipse 隐式函数求解析梯度。这里不能再用
  // min(sideDistance, verticalDistance)，否则在曲率切换处会产生法线折角。
  float profileDerivative = -6.0 * normalizedY * (1.0 - normalizedY);
  float baseDerivative = 0.0;
  if (normalizedY > 0.0001 && baseFactor > 0.0001) {
    baseDerivative = -halfWidth *
        pow(normalizedY, exponent - 1.0) *
        pow(max(1.0 - yPower, 0.0001), 1.0 / exponent - 1.0);
  }
  float leftDerivative = baseDerivative + tail * profileDerivative;
  float rightDerivative =
      baseDerivative + (bulge - compression) * profileDerivative;
  float centerDerivative = (rightDerivative - leftDerivative) * 0.5;
  float halfExtentDerivative = (leftDerivative + rightDerivative) * 0.5;
  float absX = max(abs(normalizedX), 0.000001);
  float xDerivative = exponent *
      pow(absX, exponent - 1.0) *
      sign(normalizedX) / halfExtent;
  float dNormalizedX_dY =
      (-centerDerivative * halfExtent - centeredX * halfExtentDerivative) /
      (halfExtent * halfExtent);
  float dQ_dYNorm = xDerivative * dNormalizedX_dY +
      exponent * pow(max(normalizedY, 0.000001), exponent - 1.0);
  float ySign = sign(local.y);
  vec2 gradient = vec2(
      xDerivative * directionSign,
      dQ_dYNorm * ySign / halfHeight
  );
  return LiquidState(q, gradient);
}

vec2 liquidNormal(vec2 point) {
  LiquidState state = liquidState(point);
  return normalize(state.gradient + vec2(0.0001));
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
  LiquidState state = liquidState(fragment);
  float distanceToLens = (state.q - 1.0) * halfSize.y;

  if (distanceToLens > 1.0) {
    fragColor = texture(uBackdrop, textureUv(fragment));
    return;
  }

  vec2 normal = liquidNormal(fragment);
  float q = clamp(state.q, 0.0, 1.0);
  float refractBand = smoothstep(0.62, 0.84, q) *
      (1.0 - smoothstep(0.88, 0.995, q));
  float rim = smoothstep(0.82, 0.995, q);
  float centerProfile = 1.0 - smoothstep(0.28, 0.68, q);

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
  color -= vec3(facingShade * rim * 0.035 * uLightStrength);
  // Rim 只保留很轻的厚度提示，不用无方向白线冒充玻璃边缘。
  color += vec3(rim * uRimStrength * 0.24);

  // 拖动状态略微提高边缘响应，静止时保持克制。
  color += vec3(refractBand * uDragState * 0.018);
  fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
