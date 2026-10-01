# Code Review Interview: Section 15 - Credits

**Date:** 2026-09-30

No items needed the owner's input.

## Auto-fixes
- #1 Loaded once into a `static let`.
- #2 OSError while reading VERSION or the GPL file becomes a problem line (exit 1).
- #4 The caption shows only when the app entry is present.
- #6 Preview uses `try?`.
- #7 The decode test includes an entry without `isApp`, which reads as a component.

## Let go
- #3 Duplicates are rejected by `make check`, which runs before builds.
- #5 Recorded; the scheme check is intentional.
- #8 Plan leaves `check` unchanged.
