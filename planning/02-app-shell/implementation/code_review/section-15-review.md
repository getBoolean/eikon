# Code Review: Section 15 - Credits

1. MEDIUM: `@State` initial value reloads and decodes the bundle file on every RootView update (iOS 15 builds sidebar destinations eagerly).
2. LOW: an OSError reading VERSION or the GPL file gives a traceback, not exit 1.
3. LOW: duplicate component name+revision would collide in ForEach (duplicates only rejected by `check`).
4. LOW: `[]` shows "Eikon includes no third-party components yet" with no Eikon row.
5. LOW: name only in the inline title; URLs need a scheme to link (intentional tightening).
6. LOW: preview uses `try!`.
7. NIT: no test for a missing `isApp` or the new error path.
8. NIT: `make check` doesn't check VERSION.
