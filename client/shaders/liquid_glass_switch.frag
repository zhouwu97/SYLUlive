#version 460 core
#include <flutter/runtime_effect.glsl>

// Switch adaptation of the YunKao liquid lens: opaque rail, spring-driven
// deformed field and directional rim. The sampler excludes the switch itself.
// Circle-profile refraction: Kyant0/AndroidLiquidGlass (Apache-2.0).
// SDF lighting/motion: DayDreamInAReverie/design-systems (MIT). See licenses/.
uniform vec2 uSize;
uniform vec4 uCapture;
uniform vec2 uCenter;
uniform vec2 uHalfSize;
uniform vec2 uPointer;
uniform float uPress;
uniform float uStretch;
uniform vec2 uBend;
uniform float uEnergy;
uniform float uCompare;
uniform float uDpr;
uniform float uSheen;
uniform vec3 uTrackColor;
uniform sampler2D uScene;
out vec4 fragColor;

float capsule(vec2 p, vec2 h) {
  float r = min(h.x, h.y);
  vec2 q = abs(p) - h + r;
  return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0))) - r;
}
float distanceAt(vec2 p) {
  vec2 q = p - uCenter;
  float along = 1.0 + uStretch;
  q = vec2(q.x / along, q.y * along);
  vec2 uv = clamp(q / uHalfSize, vec2(-1.3), vec2(1.3));
  q -= uBend * vec2(1.0 - uv.y * uv.y, 1.0 - uv.x * uv.x) * .7;
  return capsule(q, uHalfSize);
}
vec2 normalAt(vec2 p) {
  const float e = .35;
  vec2 n = vec2(distanceAt(p + vec2(e, 0)) - distanceAt(p - vec2(e, 0)),
                distanceAt(p + vec2(0, e)) - distanceAt(p - vec2(0, e)));
  return n / max(length(n), .0001);
}
vec3 scene(vec2 p) {
  vec2 uv = (p - uCapture.xy) / uCapture.zw;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  vec3 background = texture(uScene, clamp(uv, vec2(.001), vec2(.999))).rgb;
  float rail = capsule(p - uSize * .5, vec2(28, 15));
  float coverage = 1.0 - smoothstep(-.5 / uDpr, .5 / uDpr, rail);
  return mix(background, uTrackColor, coverage);
}
float gaussian(float x) { return exp(-x * x); }
float light(float d, vec2 n) {
  vec2 direction = normalize(vec2(-.65, -1) + (uPointer - uCenter) / uSize.x * .8);
  float a = pow(max(dot(n, direction), 0.0), 7.0);
  float b = pow(max(dot(n, -direction), 0.0), 7.0) * .52;
  float edge = clamp(1.0 + d / 8.0, 0.0, 1.0);
  float slope = pow(edge, 1.65) * .94;
  float nz = sqrt(max(1.0 - slope * slope, .001));
  float fresnel = .04 + .96 * pow(1.0 - nz, 5.0);
  return (gaussian((d + .7) / .65) * (.14 + a * .62 + b * .32)
    + gaussian((d + 1.4) / 2.0) * (.025 + a + b) * .12
    + gaussian((d + 3.0) / 1.65) * b * .07 + fresnel * .045)
    * uSheen * (1.0 - uCompare);
}
void main() {
  vec2 p = FlutterFragCoord().xy;
  float d = distanceAt(p);
  float mask = 1.0 - smoothstep(-.65 / uDpr, .65 / uDpr, d);
  if (mask < .0001) { fragColor = vec4(0); return; }
  vec2 q = p - uCenter;
  vec2 n = normalAt(p);
  vec2 radial = q / max(length(q), .0001);
  vec2 optical = n + radial;
  optical /= max(length(optical), .0001);
  float height = min(16.0, min(uHalfSize.x, uHalfSize.y) * .6);
  float band = clamp(1.0 + d / height, 0.0, 1.0);
  float circle = 1.0 - sqrt(max(0.0, 1.0 - band * band));
  vec2 offset = -optical * circle * 14.0 * (1.0 + uEnergy * .12) * (1.0 - uCompare);
  vec2 uv = q / uHalfSize;
  vec2 at = p + offset - q * (.28 * uPress * clamp(1.0 - dot(uv, uv), 0.0, 1.0) * (1.0 - uCompare));
  vec2 split = offset * (.5 * q.x * q.y / max(uHalfSize.x * uHalfSize.y, 1.0));
  split *= min(1.0, 2.5 / max(length(split), .0001));
  vec3 r = scene(at + split);
  vec3 o = scene(at + split * (2.0 / 3.0));
  vec3 y = scene(at + split * (1.0 / 3.0));
  vec3 g = scene(at);
  vec3 c = scene(at - split * (1.0 / 3.0));
  vec3 b = scene(at - split * (2.0 / 3.0));
  vec3 v = scene(at - split);
  vec3 color = vec3((r.r + o.r + y.r) / 3.5 + v.r / 7.0,
    o.g / 7.0 + (y.g + g.g + c.g) / 3.5, (c.b + b.b + v.b) / 3.0);
  color += light(d, n);
  fragColor = vec4(clamp(color, 0.0, 1.0) * mask, mask);
}
