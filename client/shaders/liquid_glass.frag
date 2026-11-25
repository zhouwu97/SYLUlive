#version 460 core
#include <flutter/runtime_effect.glsl>

// Circle-profile refraction / spectral reconstruction adapted from
// Kyant0/AndroidLiquidGlass (Copyright 2025 Kyant, Apache-2.0).
// Modified for Flutter: explicit samplers, nested dock/tab composition and SDF lighting.
// Directional Fresnel lighting informed
// by DayDreamInAReverie/design-systems (MIT). See licenses/ and README.
// All positions are LOCAL LOGICAL PIXELS. These are Paint.shader samplers,
// NOT engine-owned ImageFilter textures. The two offscreen render targets need
// an OpenGLES Y correction (including the two-row atlas, before row selection).
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
uniform float uVertical;
uniform vec3 uNavBackground;
uniform sampler2D uScene;
uniform sampler2D uTabs;
out vec4 fragColor;

float sdCapsule(vec2 p, vec2 halfSize) {
  float r = min(halfSize.x, halfSize.y);
  vec2 q = abs(p) - halfSize + r;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}
vec2 normalAt(vec2 p, vec2 halfSize) {
  vec2 q = abs(p) - halfSize + min(halfSize.x, halfSize.y);
  vec2 n = max(q, 0.0);
  if (dot(n, n) > 0.00001) return sign(p) * normalize(n);
  return sign(p) * (q.x > q.y ? vec2(1, 0) : vec2(0, 1));
}
float coverage(float d) {
  return 1.0 - smoothstep(-0.65 / uDpr, 0.65 / uDpr, d);
}
// design-systems surfaceDistance / jellyMatrix, evaluated in inverse space.
// The same curved surface drives silhouette, normals, refraction and lighting.
float lensDistance(vec2 p, vec2 h) {
  p = mat2(uInverse.xy, uInverse.zw) * p;
  vec2 uv = clamp(p / max(h, vec2(1.0)), vec2(-1.3), vec2(1.3));
  p -= uBend * vec2(1.0-uv.y*uv.y, 1.0-uv.x*uv.x) * .7;
  return sdCapsule(p, h);
}
vec2 lensGradient(vec2 p, vec2 h) {
  const float e = .35;
  vec2 n = vec2(
    lensDistance(p + vec2(e, 0), h) - lensDistance(p - vec2(e, 0), h),
    lensDistance(p + vec2(0, e), h) - lensDistance(p - vec2(0, e), h));
  return n / (2.0 * e);
}
float bevel(float d, float thickness) {
  return clamp(1.0 + d / max(thickness, .001), 0.0, 1.0);
}
float gaussian(float x) {
  return exp(-x*x);
}
vec2 bend(vec2 p, vec2 halfSize, float height, float amount, float depth) {
  float d = sdCapsule(p, halfSize);
  float band = bevel(d, height);
  float circle = 1.0 - sqrt(max(0.0, 1.0 - band * band));
  vec2 n = normalAt(p, halfSize);
  vec2 radial = p / max(length(p), .0001);
  n = n + radial * depth;
  n /= max(length(n), .0001);
  // NEGATIVE displacement: the reference pulls the scene into the bevel.
  return -n * circle * amount * (1.0 - uCompare);
}
vec3 scene(vec2 p) {
  vec2 uv = (p - uCapture.xy) / uCapture.zw;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return texture(uScene, clamp(uv, vec2(.001), vec2(.999))).rgb;
}
vec2 lightDirection(vec2 center) {
  return normalize(vec2(-.65, -1.) + (uPointer - center)
    / max(max(uSize.x, uSize.y), 1.) * .8);
}
float surfaceLight(float d, vec2 n, vec2 center, float thickness, float strength) {
  vec2 l = lightDirection(center);
  float a = pow(max(dot(n, l), 0.0), 7.0);
  float b = pow(max(dot(n, -l), 0.0), 7.0) * .52;
  float edge = bevel(d, thickness);
  float slope = pow(edge, 1.65) * .94;
  float nz = sqrt(max(1.0 - slope * slope, .001));
  float fresnel = .04 + .96 * pow(1.0 - nz, 5.0);
  float outline = gaussian((d + .7) / .65);
  float bloom = gaussian((d + 1.4) / 2.0);
  float caustic = gaussian((d + 3.0) / 1.65);
  return (outline * (.04 + a * .62 + b * .32) + bloom * (a + b) * .12
    + caustic * b * .07 + fresnel * .045) * strength * (1.0 - uCompare);
}
vec3 surfaceReflection(vec3 transmitted, float d, vec2 n, vec2 center,
    float thickness, float strength) {
  // A spectral rim remains visible on uniform scenes; scene dispersion alone
  // only separates colors where the sampled background already has contrast.
  float rim = gaussian((d + 1.0) / 1.3) * strength * (1.0-uCompare);
  vec3 spectrum = .5 + .5 * cos(vec3(0, 2.094, 4.189)
    + dot(n, vec2(.82, .57)) * 4.5);
  vec3 reflected = mix(vec3(.96), spectrum, .65);
  vec3 color = mix(transmitted, reflected, rim * .24);
  // Keep the narrow directional specular visible against a pale scene.
  return color + surfaceLight(d, n, center, thickness, strength) * .75;
}
vec4 tabs(vec2 p, float accent) {
  float itemWidth = (mix(uSize.x, uSize.y, uVertical) - 8.0) / 5.0;
  float index = clamp(floor((mix(p.x, p.y, uVertical) - 4.0) / itemWidth), 0.0, 4.0);
  float position = 4.0 + (index + .5) * itemWidth;
  vec2 center = mix(vec2(position, uSize.y * .5), vec2(uSize.x * .5, position), uVertical);
  p = center + (p - center) / (1.0 + .20 * uPress * accent);
  if (p.x < 0.0 || p.x > uSize.x || p.y < 0.0 || p.y > uSize.y) return vec4(0);
  vec2 uv = vec2(p.x / uSize.x, (p.y + uSize.y * accent) / (uSize.y * 2.0));
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return texture(uTabs, uv);
}
vec3 dock(vec2 p, float accent) {
  vec2 halfSize = uSize * .5;
  float scale = 1.0 + 16.0 / mix(uSize.x, uSize.y, uVertical) * uPress;
  vec2 h = halfSize * scale;
  vec2 q = p - halfSize;
  float d = sdCapsule(q, h);
  vec2 at = p + bend(q, h, uDockHeight, uDockAmount, 0.0);
  vec3 c = scene(at);
  float luma = dot(c, vec3(.2126, .7152, .0722));
  c = mix(vec3(luma), c, 1.12);
  c = mix(c, uNavBackground, uTint);
  c = surfaceReflection(c, d, normalAt(q, h), halfSize, uDockHeight, .75);
  c = mix(scene(p), c, coverage(d));
  vec4 ink = tabs(p, accent);
  return ink.rgb + c * (1.0 - ink.a);
}
void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 dockHalf = uSize * .5 * (1.0 + 16.0 / mix(uSize.x, uSize.y, uVertical) * uPress);
  float dd = sdCapsule(p - uSize * .5, dockHalf);
  vec2 lc = uLens.xy + uLens.zw * .5;
  vec2 halfSize = uLens.zw * .5;
  vec2 q = p - lc;
  // Correct the deformed field locally before using logical-pixel bevel widths.
  vec2 gradient = lensGradient(q, halfSize);
  float magnitude = max(length(gradient), .001);
  vec2 n = gradient / magnitude;
  float ld = lensDistance(q, halfSize) / magnitude;
  float lm = coverage(ld);
  float mask = max(coverage(dd), lm);
  if (mask <= .0001) { fragColor = vec4(0); return; }
  vec3 c = dock(p, 0.0);
  // Contact shading follows the deformed boundary; it also keeps the moving
  // lens readable over pale content without adding an opaque panel.
  c *= 1.0 - exp(-max(ld, 0.0)/5.0) * .12 * clamp(uPress+uEnergy,0.,1.)
    * (1.0-lm) * (1.0-uCompare);
  if (lm > .0001) {
    float thickness = max(uLensHeight * uPress, .001);
    float band = bevel(ld, thickness);
    float circle = 1.0 - sqrt(max(0.0, 1.0 - band * band));
    vec2 offset = -n * circle * uLensAmount * uPress
      * (1.0+uEnergy*.12) * (1.0-uCompare);
    vec2 at = p + offset;
    float spread = uDispersion * pow(band, 2.8) * clamp(uPress, 0.0, 1.0) * 3.2;
    vec2 split = n * min(spread, 2.0) * (1.0-uCompare);
    vec3 r = dock(at + split, 1.0);
    vec3 o = dock(at + split * (2.0/3.0), 1.0);
    vec3 y = dock(at + split * (1.0/3.0), 1.0);
    vec3 g = dock(at, 1.0);
    vec3 cyan = dock(at - split * (1.0/3.0), 1.0);
    vec3 b = dock(at - split * (2.0/3.0), 1.0);
    vec3 v = dock(at - split, 1.0);
    vec3 lens = vec3((r.r+o.r+y.r)/3.5+v.r/7.0,
      o.g/7.0+(y.g+g.g+cyan.g)/3.5, (cyan.b+b.b+v.b)/3.0);
    lens = mix(lens, vec3(uDark), mix(.08, .12, uDark) * (1.0-clamp(uPress,0.,1.)));
    lens *= 1.0 - .012 * uPress;
    // Keep a shaded face and directional rim so pale backgrounds retain a lens.
    float shadedFace = .35 + .65 * max(dot(n, -lightDirection(lc)), 0.0);
    lens -= gaussian((ld+3.0)/5.0) * .055 * shadedFace * uPress * (1.0-uCompare);
    lens = surfaceReflection(lens, ld, n, lc, thickness, uPress);
    float glint = exp(-length((p-uPointer)/vec2(90,70))*2.0);
    lens = mix(lens, vec3(1), glint * .02 * uPress * (1.0-uCompare));
    c = mix(c, lens, lm);
  }
  fragColor = vec4(clamp(c, 0.0, 1.0) * mask, mask);
}
