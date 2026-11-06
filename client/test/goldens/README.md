# Golden Baselines

## Reproducible environment

Canonical baselines are generated on Linux using the same Ubuntu runner and pinned Flutter version as the client job in [CI](../../../.github/workflows/ci.yml). The [baseline workflow](../../../.github/workflows/golden-baselines.yml) must use the same environment.

Windows can run checks and capture layout evidence, but must not update canonical baselines: font rasterization and rendering can differ by platform. Do not manually edit PNG files.

## Review and update

1. Confirm that the visual change is intended and inspect the real rendered result, including affected loading, empty, error, dark-theme, and large-text states.
2. Run the relevant Widget and interaction tests. Golden comparisons do not replace behavior tests or device checks.
3. Generate or update baselines through `.github/workflows/golden-baselines.yml` and review the image differences before accepting them.

The workflow runs `flutter test test/goldens --update-goldens`. Do not update baselines simply to make a failing comparison pass. Record the viewport, theme, text scale, state, and verification result with the change; use the relevant profiles in `test/helpers/` rather than duplicating viewport setup.

Main CI continues to verify existing baselines with `flutter test`. General UI acceptance and evidence requirements are maintained in [DEVELOPMENT_STANDARD.md](../../../DEVELOPMENT_STANDARD.md#42-flutter-与客户端).
