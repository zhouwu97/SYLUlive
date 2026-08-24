#version 460 core

#include <flutter/runtime_effect.glsl>

// uSize 是完整的 overscan 捕获纹理。可见 Lens 使用独立的中心和半尺寸，
// 光学采样不会把可见边缘误当成纹理边缘。
uniform vec2 uSize;
uniform vec2 uLensCenter;
uniform vec2 uLensHalfSize;
uniform float uLensExponent;
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

struct LiquidState {
  float q;
  vec2 gradient;
};

float smoothProfile(float value) {
  float t = clamp(value, 0.0, 1.0);
  return 1.0 - t * t * (3.0 - 2.0 * t);
}

LiquidState liquidState(vec2 point) {
  vec2 local = point - uLensCenter;
  float directionSign = uDirection < -0.01 ? -1.0 : 1.0;
  float halfHeight = max(uLensHalfSize.y, 0.001);
  float exponent = clamp(uLensExponent, 2.02, 3.5);
  float flow = clamp(uFlowStrength, 0.0, 1.4);
  float tail = halfHeight * uVelocity * 0.45 * flow;
  float bulge = halfHeight * uVelocity * 0.28 * flow;
  float compression = halfHeight * uEdgeCompression * 0.16 * flow;
  float halfWidth = max(
      uLensHalfSize.x - max(tail, bulge - compression),
      halfHeight * 0.72
  );

  float normalizedY = clamp(abs(local.y) / halfHeight, 0.0, 1.0);
  float yPower = pow(normalizedY, exponent);
  float baseFactor = pow(max(1.0 - yPower, 0.0001), 1.0 / exponent);
  float baseExtent = halfWidth * baseFactor;
  float profile = smoothProfile(normalizedY);

  float leftExtent = baseExtent + tail * profile;
  float rightExtent = baseExtent + (bulge - compression) * profile;
  float centerShift = (rightExtent - leftExtent) * 0.5;
  float halfExtent = max((leftExtent + rightExtent) * 0.5, 0.001);
  float canonicalX = local.x * directionSign;
  float centeredX = canonicalX - centerShift;
  float normalizedX = centeredX / halfExtent;
  float q = pow(abs(normalizedX), exponent) + yPower;

  // 对 q 使用的同一个 superellipse 隐式函数求解析梯度。距离场有限差分会在
  // 上下过渡处引入明显的法线台阶，使折射看起来像有棱角。
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
      pow(absX, exponent - 1.0) * sign(normalizedX) / halfExtent;
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

vec2 liquidNormal(LiquidState state) {
  float lengthSquared = dot(state.gradient, state.gradient);
  if (lengthSquared < 0.0000001) return vec2(0.0, 1.0);
  return state.gradient / sqrt(lengthSquared);
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
  float pressDepth = clamp(uPressDepth, 0.0, 1.0);
  float refraction = uRefraction * activation;
  float magnification = 1.0 + (uMagnification - 1.0) * activation;
  float chromatic = uChromatic * activation;
  float lightStrength = uLightStrength * activation;
  float rimStrength = uRimStrength * activation;

  // Identity 是显式闸门。除了便于 QA 对照，还能让无效果路径保持像素稳定，
  // 避免执行不必要的颜色计算。
  if (activation <= 0.0001 ||
      (refraction == 0.0 &&
       magnification == 1.0 &&
       chromatic == 0.0 &&
       lightStrength == 0.0 &&
       rimStrength == 0.0)) {
    fragColor = original;
    return;
  }

  LiquidState state = liquidState(fragment);
  float q = clamp(state.q, 0.0, 1.0);
  vec2 normal = liquidNormal(state);

  // q=1 附近使用平滑 coverage，shader 只保留一条光学边界。捕获区域仍是矩形，
  // 解析曲面之外的像素自然混回未处理的背景。
  float aa = max(fwidth(state.q), 0.0005);
  float glassMask = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, state.q);

  // 横向液态 Lens 以 x 方向法线为主；上下厚度同时受各向异性和 sideWeight 克制。
  float sideWeight = pow(clamp(abs(normal.x), 0.0, 1.0), 1.7);
  vec2 opticalNormal = normalize(vec2(
      normal.x,
      normal.y * max(uVerticalRefractionScale, 0.08)
  ));
  float leadingBand = smoothstep(
      uRefractionBandStart,
      uRefractionBandPeak,
      q
  );
  float trailingBand = 1.0 - smoothstep(
      uRefractionBandPeak,
      uRefractionBandEnd,
      q
  );
  float refractionBand = leadingBand * trailingBand;
  float thickness = pow(max(1.0 - q, 0.0), 0.55);
  float opticalStrength = refractionBand *
      mix(0.25, 1.0, sideWeight) *
      (0.84 + thickness * 0.28) *
      glassMask;

  float centerProfile = 1.0 - smoothstep(
      0.0,
      max(uMagnificationRadius, 0.08),
      q
  );
  float zoom = mix(1.0, uMagnification, centerProfile * glassMask);
  vec2 samplePixel = uLensCenter + (fragment - uLensCenter) / zoom;
  samplePixel -= opticalNormal * opticalStrength * refraction;

  float chromaticBand = smoothstep(
      uChromaticStart,
      min(uChromaticStart + 0.10, 0.995),
      q
  ) * (1.0 - smoothstep(0.975, 0.999, q));
  vec2 chromaticOffset = opticalNormal * chromatic * chromaticBand *
      mix(0.30, 1.0, sideWeight) * glassMask;
  vec3 color = vec3(
      texture(uBackdrop, textureUv(samplePixel - chromaticOffset)).r,
      texture(uBackdrop, textureUv(samplePixel)).g,
      texture(uBackdrop, textureUv(samplePixel + chromaticOffset)).b
  );

  float finalSignal = clamp(
      (magnification - 1.0) * 8.0 +
      chromatic * 0.12 +
      lightStrength * 0.45,
      0.0,
      1.0
  ) * glassMask;
  float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
  color = mix(vec3(luma), color, 1.0 + 0.08 * finalSignal);
  color = (color - 0.5) * (1.0 + 0.03 * finalSignal) + 0.5;
  color = mix(color, uTint.rgb, uTint.a * glassMask);

  float outerRim = smoothstep(0.82, 0.95, q) *
      (1.0 - smoothstep(0.965, 0.999, q)) * glassMask;
  vec2 lightDirection = normalize(
      vec2(-0.72 + uDirection * uVelocity * 0.12, -0.70)
  );
  float facingLight = max(dot(opticalNormal, lightDirection), 0.0);
  float facingShade = max(dot(opticalNormal, -lightDirection), 0.0);
  float specular = pow(facingLight, 4.0) * outerRim;
  color += vec3(specular * lightStrength * 1.10);
  color -= vec3(facingShade * outerRim * 0.055 * lightStrength);

  vec3 dispersionTint = mix(
      vec3(0.54, 0.76, 1.0),
      vec3(1.0, 0.70, 0.36),
      clamp(opticalNormal.x * 0.5 + 0.5, 0.0, 1.0)
  );
  color += dispersionTint * outerRim * rimStrength * 0.78;
  color += dispersionTint * refractionBand * uDragState * 0.018 * glassMask *
      activation;

  // 按下反馈只在玻璃正在被抓住时轻微偏暖，避免用整块白色覆盖伪造材质。
  color += vec3(0.035, 0.018, -0.004) * pressDepth * glassMask;

  fragColor = vec4(clamp(mix(original.rgb, color, glassMask), 0.0, 1.0), original.a);
}
