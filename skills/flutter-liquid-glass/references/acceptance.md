# Liquid glass quality criteria

These are material and interaction criteria, not product design requirements. Select applicable checks for the requested component.

## Optical quality

- Actual underlying content is transmitted and visibly refracted near curved/thick regions; compare with a blur-only control.
- Clear glass preserves scene detail; frosted glass scatters it intentionally. Neither relies on an opaque white fill to hide missing optics.
- Silhouette, normal field, refraction and lighting describe the same surface. Shape deformation does not leave static highlights or seams behind.
- Edges are stable at the target DPR. No capture feedback, cropped glow, inverted text, texture stretch at capture bounds, duplicated foreground or unexplained dark fringe.
- Reflection and dispersion are restrained and consistent with the chosen material. Readability remains adequate across light/dark/textured backgrounds.

## Motion quality

- Input affects the surface without discontinuous jumps. Motion has a purpose appropriate to the control.
- Slow and fast input differ where velocity-driven deformation is intended; displacement lag, stretch and bend are coupled rather than random wobble.
- Hold, release, reversal and re-grab remain continuous. Springs converge and idle frames stop.
- Different frame rates yield comparable trajectories. Missing sensor pressure is not represented as measured force.
- Cancellation, pointer ownership, keyboard/semantic actions and reduced motion preserve the host's interaction contract.

## Validation method

Use an identical scene, viewport, DPR, material and input trace for comparisons. Inspect static images for optical faults and sampled position/shape traces or recordings for temporal faults. Include a patterned diagnostic scene and realistic host content. Test supported native/web backends separately; report limitations instead of inferring device parity from source code.

For portability testing, choose at least two different component types (for example a draggable lens and a pressable card) with different shapes, colors and content. Success is consistent optical/material quality and appropriate responsive motion, not reproduction of a five-tab navigation bar or its settings page.

Optional configuration, if requested by a host, should be internally consistent and persist according to that product's requirements. There are no mandated performance modes, percentages, clear-mode switches, onboarding messages or storage keys in this skill.
