#version 460 core

#include <flutter/runtime_effect.glsl>

// Kyant AndroidLiquidGlass DefaultHighlight 的 Flutter Runtime Shader 移植。
// Apache-2.0 参考：Kyant0/AndroidLiquidGlass。
uniform vec2 uSize;
uniform vec4 uCornerRadii;
uniform vec4 uColor;
uniform float uAngle;
uniform float uFalloff;

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

void main() {
  vec2 coord = FlutterFragCoord().xy;
  vec2 halfSize = uSize * 0.5;
  vec2 centeredCoord = coord - halfSize;
  float radius = clamp(
      uCornerRadii.x,
      0.0,
      min(halfSize.x, halfSize.y)
  );
  float gradRadius = min(radius * 1.5, min(halfSize.x, halfSize.y));
  vec2 grad = gradSdRoundedRect(centeredCoord, halfSize, gradRadius);
  vec2 normal = vec2(cos(uAngle), sin(uAngle));
  float intensity = pow(abs(dot(grad, normal)), max(uFalloff, 0.0001));
  fragColor = uColor * intensity;
}
