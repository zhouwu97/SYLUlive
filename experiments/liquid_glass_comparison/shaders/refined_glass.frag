#version 460 core
#include <flutter/runtime_effect.glsl>

// Derived from FlutterLiquidglass a37134b (MIT), Kyant0/AndroidLiquidGlass
// (Apache-2.0) and design-systems (MIT). Original notices are in licenses/.
// Uniforms and samplers match the pristine reference shader.
uniform vec2 uSize;
uniform vec4 uCapture;
uniform vec4 uLens;
uniform vec2 uPointer;
uniform float uPress;
uniform float uDark;
uniform float uDockAmount;
uniform float uDockHeight;
uniform float uLensAmount;
uniform float uLensHeight;
uniform float uDispersion;
uniform float uTint;
uniform float uCompare;
uniform float uDpr;
uniform vec2 uBend;
uniform vec4 uInverse;
uniform float uEnergy;
uniform sampler2D uScene;
uniform sampler2D uTabs;
out vec4 fragColor;

float capsule(vec2 p, vec2 h) {
  float r = min(h.x, h.y);
  vec2 q = abs(p) - h + r;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}
vec2 capsuleNormal(vec2 p, vec2 h) {
  vec2 q = abs(p) - h + min(h.x, h.y);
  vec2 n = max(q, 0.0);
  if (dot(n, n) > .00001) return sign(p) * normalize(n);
  return sign(p) * (q.x > q.y ? vec2(1, 0) : vec2(0, 1));
}
float field(vec2 p, vec2 h) {
  p = mat2(uInverse.xy, uInverse.zw) * p;
  vec2 uv = clamp(p / max(h, vec2(1)), vec2(-1.3), vec2(1.3));
  p -= uBend * vec2(1.0 - uv.y * uv.y, 1.0 - uv.x * uv.x) * .7;
  return capsule(p, h);
}
vec2 gradientAt(vec2 p, vec2 h) {
  const float e = .35;
  return vec2(field(p + vec2(e, 0), h) - field(p - vec2(e, 0), h),
    field(p + vec2(0, e), h) - field(p - vec2(0, e), h)) / (2.0 * e);
}
float coverage(float d) {
  return 1.0 - smoothstep(-.65 / uDpr, .65 / uDpr, d);
}
vec3 scene(vec2 p) {
  vec2 uv = (p - uCapture.xy) / uCapture.zw;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return texture(uScene, clamp(uv, vec2(.001), vec2(.999))).rgb;
}
vec4 tabs(vec2 p, float accent) {
  float item = (uSize.x - 8.0) / 5.0;
  float index = clamp(floor((p.x - 4.0) / item), 0.0, 4.0);
  vec2 center = vec2(4.0 + (index + .5) * item, 32.0);
  p = center + (p - center) / (1.0 + .20 * uPress * accent);
  if (p.x < 0.0 || p.x > uSize.x || p.y < 0.0 || p.y > 64.0) return vec4(0);
  vec2 uv = vec2(p.x / uSize.x, (p.y + 64.0 * accent) / 128.0);
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return texture(uTabs, uv);
}
float bevel(float d, float thickness) {
  return clamp(1.0 + d / max(thickness, .001), 0.0, 1.0);
}
float circularOffset(float edge) {
  return 1.0 - sqrt(max(0.0, 1.0 - edge * edge));
}
vec3 surfaceNormal(vec2 n, float edge) {
  float slope = pow(edge, 1.65) * .94;
  return vec3(n * slope, sqrt(max(1.0 - slope * slope, .001)));
}
vec3 reflectSurface(vec3 transmitted, vec2 p, vec2 n, float d,
    float thickness, vec2 center, float strength) {
  float edge = bevel(d, thickness);
  vec3 normal = surfaceNormal(n, edge);
  vec2 light = normalize(vec2(-.65, -1.0) + (uPointer - center) / max(uSize.x, 1.0) * .8);
  float mainLight = pow(max(dot(n, light), 0.0), 7.0);
  float opposite = pow(max(dot(n, -light), 0.0), 7.0) * .42;
  float fresnel = .04 + .96 * pow(1.0 - normal.z, 5.0);
  float rim = exp(-pow((d + .65) / .8, 2.0));
  float bloom = exp(-pow((d + 1.65) / 2.4, 2.0));
  float caustic = exp(-pow((d + thickness * .28) / 1.8, 2.0));
  vec3 environment = scene(p + n * 20.0);
  float amount = fresnel * .12 * strength * (1.0 - uCompare);
  vec3 color = mix(transmitted, environment, amount);
  vec3 lightColor = mix(vec3(1), environment, .16);
  float spec = rim * (.065 + mainLight * .36 + opposite * .20)
    + bloom * (mainLight + opposite) * .075 + caustic * opposite * .045;
  color = mix(color, lightColor, clamp(spec * strength * (1.0 - uCompare), 0.0, .65));
  return color;
}
vec3 dock(vec2 p, float accent) {
  vec2 halfSize = uSize * .5;
  vec2 h = halfSize * (1.0 + 16.0 / uSize.x * uPress);
  vec2 q = p - halfSize;
  float d = capsule(q, h);
  vec2 n = capsuleNormal(q, h);
  float edge = bevel(d, uDockHeight);
  vec2 at = p - n * circularOffset(edge) * uDockAmount * (1.0 - uCompare);
  vec3 c = scene(at);
  float luma = dot(c, vec3(.2126, .7152, .0722));
  c = mix(vec3(luma), c, 1.12);
  c = mix(c, mix(vec3(1), vec3(.082), uDark), uTint);
  c = reflectSurface(c, p, n, d, uDockHeight, halfSize, .65);
  c = mix(scene(p), c, coverage(d));
  vec4 ink = tabs(p, accent);
  return ink.rgb + c * (1.0 - ink.a);
}
void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 dockHalf = uSize * .5 * (1.0 + 16.0 / uSize.x * uPress);
  float dd = capsule(p - uSize * .5, dockHalf);
  vec2 lc = uLens.xy + uLens.zw * .5;
  vec2 halfSize = uLens.zw * .5;
  vec2 q = p - lc;
  vec2 gradient = gradientAt(q, halfSize);
  float magnitude = max(length(gradient), .001);
  vec2 n = gradient / magnitude;
  float ld = field(q, halfSize) / magnitude;
  float lm = coverage(ld);
  float mask = max(coverage(dd), lm);
  if (mask <= .0001) { fragColor = vec4(0); return; }
  vec3 c = dock(p, 0.0);
  float activation = clamp(uPress, 0.0, 1.0);
  c *= 1.0 - exp(-max(ld, 0.0) / 4.5) * .045 * activation
    * (1.0 - lm) * (1.0 - uCompare);
  if (lm > .0001) {
    float thickness = max(uLensHeight * uPress, .001);
    float edge = bevel(ld, thickness);
    vec2 offset = -n * circularOffset(edge) * uLensAmount * uPress
      * (1.0 + uEnergy * .12) * (1.0 - uCompare);
    vec2 at = p + offset;
    float spread = uDispersion * pow(edge, 2.8) * activation * 3.2;
    vec2 split = n * min(spread, 2.0) * (1.0 - uCompare);
    vec3 r = dock(at + split, 1.0);
    vec3 o = dock(at + split * (2.0 / 3.0), 1.0);
    vec3 y = dock(at + split * (1.0 / 3.0), 1.0);
    vec3 g = dock(at, 1.0);
    vec3 cyan = dock(at - split * (1.0 / 3.0), 1.0);
    vec3 b = dock(at - split * (2.0 / 3.0), 1.0);
    vec3 v = dock(at - split, 1.0);
    vec3 lens = vec3((r.r + o.r + y.r) / 3.5 + v.r / 7.0,
      o.g / 7.0 + (y.g + g.g + cyan.g) / 3.5, (cyan.b + b.b + v.b) / 3.0);
    lens = mix(lens, vec3(uDark), mix(.08, .12, uDark) * (1.0 - activation));
    lens = reflectSurface(lens, p, n, ld, thickness, lc, uPress);
    float glint = exp(-length((p - uPointer) / vec2(90, 70)) * 2.0);
    lens = mix(lens, vec3(1), glint * .014 * activation * (1.0 - uCompare));
    c = mix(c, lens, lm);
  }
  fragColor = vec4(clamp(c, 0.0, 1.0) * mask, mask);
}
