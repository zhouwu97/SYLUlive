# CLAUDE.md

Before any task, read DEVELOPMENT_STANDARD.md and CONTRIBUTING.md. Keep changes scoped to the request, preserve unrelated worktree changes, and do not push, rewrite history, change repository permissions, or perform production operations without explicit authorization.

When changing Flutter UI, interaction or motion:

- Inspect the current theme, shared widgets, adjacent screens, and relevant tests. Follow the current task's design requirements and DEVELOPMENT_STANDARD.md for verification.
- docs/design/ retains feature contracts and decision records, not a global visual specification. Respect its active business and permission ADRs.
