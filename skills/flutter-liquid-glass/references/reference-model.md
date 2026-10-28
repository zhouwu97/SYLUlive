# Accepted reference model

Design-systems: https://github.com/ruiqichenbiec/design-systems/tree/7a424c93b9be13cf835b91ea67495fec2ec0584e
Read lens/lab/design-system/internal/jelly.js, jelly-physics.js, optical-motion.js and renderer.js together.
LocationSpoofer: https://github.com/TaoCultivator/LocationSpoofer/tree/44e1ce221e47499b973fb1a1400fe8e45c9403a8
Flutter example: https://github.com/zhouwu97/-Liquid-Glass
Read lib/widgets/liquid_bottom_nav.dart, lib/widgets/liquid_glass/ and shaders/liquid_glass.frag. Check the repository version before copying; host contracts differ.

## Motion

Each spring: acceleration = (target - value) * stiffness - velocity * damping.
Substeps <= 1/180 second; long frame delta capped at 0.08 seconds.
Position stiffness 260, damping 22 held / 17 released.
Press 310/18; stretch 230/15; bend 190/14.
stretch.target = min(speed / 2400, 0.25).
bend.target = clamp((pointerTarget - springPosition) * 0.12, -11, 11).
Use consistent pixel units for velocity/lag.
Stretch along velocity by 1 + stretch and compress across by the reciprocal.
Shader: p = inverseStretch * p; uv = clamp(p / halfSize, -1.3, 1.3);
p -= bend * vec2(1 - uv.y*uv.y, 1 - uv.x*uv.x) * 0.7.
Evaluate capsule SDF and derive normals from this transformed field.

The demo expands pressed lens height 56 toward 78 and uses its own tint. These are adaptation choices, not pixel identity claims.

## Example shader contract

29 scalar floats: size 0..1, capture 2..5, lens 6..9, pointer 10..11, press 12, dark 13, dock amount/height 14..15, lens amount/height 16..17, dispersion 18, tint 19, comparison 20, DPR 21, bend 22..23, inverse matrix 24..27, energy 28.
Sampler 0 = scene; sampler 1 = two-row foreground atlas.
Dart setters and GLSL uniform declarations must change together.
The example corrects offscreen texture Y only under IMPELLER_TARGET_OPENGLES. Test other backends before changing that condition.
