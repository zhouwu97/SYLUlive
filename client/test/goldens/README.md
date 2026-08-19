# Golden Baselines

Canonical platform:

```text
Ubuntu
Flutter 3.41.8 stable
```

Rules:

```text
Do not manually edit PNG files.

Generate/update via:
.github/workflows/golden-baselines.yml

Golden update is allowed only after
DESIGN_QA review confirms the visual change.
```

See `docs/design/DESIGN_QA.md` for the full protocol.

Future layout:

```text
client/test/goldens/
├── baselines/
│   ├── chat/
│   ├── home/
│   └── edu/
└── *_golden_test.dart
```