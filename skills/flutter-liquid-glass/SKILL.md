---
name: flutter-liquid-glass
description: Implement and debug Flutter liquid glass controls with live background refraction, velocity-driven elastic deformation and pixel-level validation. Use for liquid navigation bars and glass lenses that feel rigid during dragging.
---

# Flutter liquid glass

Treat material and motion as one system. A blurred capsule with a translation animation does not reproduce a deforming optical lens.

## Reference and integration boundary

Read the actual reference implementation, including gesture physics and shader helpers; pin its commit. Compare slow drag, fast drag, reversal, cancellation and release, not just screenshots. Preserve attribution and upstream licenses when porting.

Locate the host navigation callbacks, selected state, visual-position notifier, wallpaper, Scaffold, safe area, keyboard behavior, performance preferences and theme. Keep business navigation in the host. Put a scene source above Scaffold and a capture boundary around its background/body. The bottom bar consumes that source but must not be recorded into itself. Include wallpaper when page content is transparent.

## Couple shape to motion

Use continuous springs for position, press, stretch and bend. Update targets on pointer input instead of restarting fixed-duration tweens. Preserve velocity on release and reversal; integrate elapsed time with bounded substeps.

Stretch follows velocity; bend follows lag between pointer target and spring position. Hardware pressure is optional: ordinary mouse/default pressure is not a force sensor. Apply inverse stretch and bend to the signed-distance field before deriving its normal. Use that same boundary for coverage, refraction and lighting.

Read [reference-model.md](references/reference-model.md) for the accepted baseline equations. Parameters are a starting point rather than universal values.

Keep one owner of visual position during dragging and settling. Do not feed a parent's page tween back into the lens spring. Commit once on release and distinguish internal commits from external navigation. Track one pointer, support cancellation/re-grab, and retain semantic and keyboard activation.

## Render actual optics

Capture the live scene and a separate icon/label atlas when those elements must refract. Keep shader coordinates, capture padding and DPR consistent, with enough paint space for the enlarged lens.

Use readable text and asymmetric content to verify texture orientation. Apply backend-specific Y correction only with evidence. Claim full optics only after successful capture and shader paint; provide usable blur fallback when disabled or unsupported.

Avoid CPU image readback and capture timers in the frame loop. Invalidate during existing scene/gesture frames and verify no idle frame loop. Dispose images, shaders and listeners. Optional tilt sensors should stop when the activity pauses.

## Validate and deliver

Test a patterned scene for displacement versus blur-only output, both bend directions, foreground refraction, capture offsets, DPR and alpha. Compare slow/fast motion, pressure where supported, and 60/120 Hz integration.

Exercise actual host navigation, parent callbacks, cancellation, multi-touch, accessibility, reduced motion, fallback, light/dark themes, large text and tablet resizing. Assert touch targets and single commits. Inspect rendered images; widget existence and shader-string tests do not prove optics.

Compile the actual Android application. After switching release/debug or integration-test modes, allow Flutter plugin regeneration: blindly using --no-pub can leave GeneratedPluginRegistrant inconsistent. Record the build mode and hardware/backend actually checked.

Report remaining differences honestly. Fidelity does not imply identical pixels across browser, Skia, Impeller and physical devices. This skill does not authorize pushing or deployment beyond the user's task.
