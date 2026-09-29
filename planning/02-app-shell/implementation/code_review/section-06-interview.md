# Code Review Interview: Section 06 - Route picker

**Date:** 2026-09-29

## Discussed with user

- **Plan contradiction: test 4a vs the rules table.** Test 4a expected an i386 game to fall back to wine-box64 when wine-fex fails x18, but the table requires x18 for wine-box64 too. User: "i don't know, figure it out." Resolved from requirements.md and split 14's spec: the Box64 route still runs Wine's Windows ARM64 modules, which keep the TEB in x18 (Madeira's x18 workaround applies to both routes). The table stands; row 4a was dropped. Box64's fallback stays covered by the declined and not-built rows.
- User asked how Madeira solves x18: it patches x18 reads in Windows ARM64/ARM64EC modules into trampolines that read the TEB from TPIDRRO_EL0, with a fault handler and dispatcher restore. Madeira is JIT-only (no Box64 route).

## Auto-fixes

- #1 Order: native, wine-fex, wine-box64, linux-fex, then other engines' native routes.
- #2 Ordering reasons only on candidates that aren't unavailable.
- #3 Rules have architecture-independent `gates` plus `gatesByArchitecture`.
- #4 `RouteRules.rule(for:)` and `nativeRoute(for:)` are exhaustive switches.
- #5 The overridden candidate is updated in `candidates` too.
- #6 Row: an unbuilt route with a declined check is still planned and chosen.
