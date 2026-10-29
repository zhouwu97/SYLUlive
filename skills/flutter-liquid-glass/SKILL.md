---
name: flutter-liquid-glass
description: Create and refine convincing liquid glass materials and responsive motion in Flutter, including live refraction, deformable surfaces, coherent lighting and backend validation. Applies to controls, cards, panels, lenses and navigation without prescribing a product layout or settings UI.
---

# Flutter liquid glass

Build the requested component's material and interaction, not a copy of a particular application. Liquid glass is a coupled optical surface and motion system. Blur, opacity and a rounded rectangle alone are insufficient.

## Determine the intended material

Use the user's visual reference when supplied. Otherwise choose a coherent glass treatment appropriate to the component and background. Decide thickness, clear versus frosted transmission, edge curvature, tint, reflection, and how interaction changes the surface. Keep the host's content, branding and navigation semantics. Do not add settings, performance presets, onboarding, five tabs, blue accents, fixed dimensions or persistence unless the task calls for them.

Read references/acceptance.md for quality criteria. Use references/reference-model.md only when its example physics or shader architecture helps; its numbers and uniform layout are an implementation example, not a universal specification.

## Construct coherent optics

Capture the actual scene behind the surface, excluding the surface itself. Include underlying wallpaper and scrollable content. Choose capture boundaries and coordinate transforms for the host layout; a Stack overlay and a Scaffold bottom bar need different integration boundaries.

Define a signed-distance field for the chosen shape. Derive its coverage, surface normal and optical thickness consistently. Use thickness/normal to displace scene samples, with plausible reflection and edge lighting. Introduce subtle dispersion only where it contributes to the intended material. Keep highlights directional and coherent with shape; avoid white outlines, uniform white overlays and exaggerated rainbows masquerading as glass.

Separate frost from transmission: blur controls detail scattering; tint controls absorption/color, not a substitute for transparency. Do not automatically remove frost on press unless that transition is part of the desired design. Preserve legibility without making the entire surface opaque. If content is meant to sit inside the glass, include it in the optical composition; if it sits above the surface, keep it crisp intentionally.

Keep logical coordinates, DPR, capture padding and texture orientation consistent. Check readable text and asymmetric patterns on each renderer. Do not apply a global texture flip because one backend needs correction. A Paint.shader path with explicit scene/foreground samplers is a useful cross-backend architecture; unsupported features must have an honest fallback, not a false full-quality status.

## Make motion physical and interruptible

Select the interaction model for the component: a button compresses, a slider follows input, a card may tilt, and a draggable lens stretches and bends. Do not force drag-to-select semantics onto unrelated controls.

For deformable glass, maintain continuous spring state. Map velocity to directional stretch, displacement lag to bend, and actual supported pressure to compression/expansion. Use inverse stretch and bend inside the surface field so silhouette, normals, refraction and highlights deform together. Compensate cross-axis stretch where appropriate to avoid arbitrary inflation.

Update targets rather than restarting a fixed-duration animation on every pointer event. Preserve position and velocity when interrupted or reversed. Bound integration substeps and frame delta; compare behavior at different refresh rates. A press traveling toward an input target should activate from its current location and move continuously, not teleport first. This rule applies only when that traveling interaction is desired.

Handle release, cancellation, re-grab and multiple pointers explicitly. Keep visual motion ownership separate from host business transitions so stale host animation cannot pull the surface backward. Commit actions at the correct phase for the control; preserve keyboard and semantic activation. Respect reduced motion while retaining understandable state feedback.

## Keep rendering sustainable

Prefer GPU composition. Avoid CPU image readback in the animation loop. Capture only the needed region with sufficient optical/blur padding, reuse resources where valid, dispose textures/listeners and stop scheduling frames when idle. Optional sensor effects must stop in the background. Measure rather than equating a smaller animation amplitude with guaranteed GPU savings.

## Verify and refine

Use the actual component over text, grids, photos, pale content and dark content. Verify scene displacement, edge continuity, no double images, no clipping, stable texture orientation and foreground legibility. Compare resting, initial press, movement, fast movement, reversal, release and cancellation where applicable. Validate continuity and response rather than merely checking widget presence or shader strings.

Inspect real rendered images and motion, then adjust one optical or physical parameter group at a time. Preserve evidence of before/after differences. Static screenshots cannot prove dynamic quality, and desktop widget tests cannot prove Android GPU behavior. Record which backend/device was actually checked. Build/run the requested targets when allowed; if builds are prohibited, state that the visual result remains unverified there. Do not promise perfect or identical pixels across all devices without evidence.

## Optional worked example

assets/reference_flutter contains a licensed, runnable navigation example illustrating scene capture, a two-layer optical composition and continuous spring deformation. It is teaching material, not the required output or a business-settings template. Extract/adapt the rendering and physics for the requested shape and interaction. Do not copy its demo pages, five destinations, sizes, colors or settings by default.

To explore it in isolation, create a new Flutter application named bottom_nav_demo, overlay its bundled lib/, shaders/, assets/, test/, licenses/ and pubspec.yaml, then run dependency resolution and tests. Never overlay a business project wholesale. android-reference/ contains optional gravity-channel code; merge only if needed, preserving host package/channels. The example was tested on Flutter 3.41.8 / Dart 3.11.5; verify API and backend compatibility for the destination SDK. Redistribute bundled assets with their licenses.
