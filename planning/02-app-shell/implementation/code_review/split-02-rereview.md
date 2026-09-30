# Split 02 re-review (sections 01–07)

**Date:** 2026-09-29. One agent reviewed 384be79..HEAD for cross-section issues. Every finding was checked against the code and plans and confirmed; all were fixed.

| Finding | Fix |
|---|---|
| H1 Section 09's copy-finished/change checks were top-level only, but the exact fingerprint hashes the whole tree | `FingerprintBuilder.contentStamp` (recursive path/size/mtime, same exclusions, directory mtimes ignored); section 09 uses it for quiescence and re-fingerprinting, and discards a hash whose stamp changed while it ran |
| H2 Launch and settings waited on the full hash (plans said "a second or two") | `FingerprintBuilder.engineID` + `IdentityMatcher.quickMatch` (known location, engine id): an id at once, provisional if new; the full pass merges a provisional game with no user data silently, else suggests. Sections 09/13 and claude-plan updated |
| M1 Store keyed fingerprints by the whole value; identity compares `exact` only; opposite list orders | Store API takes `Fingerprint`, keys on `exact`, returns oldest first |
| M2 `retire_fd` could spin forever on a writer that never returns | Bounded wait (~100 ms), then leak the fd |
| M3 Section 10's recorder omitted the breadcrumb ring; opening it before `arm` loses every breadcrumb | Section 10 spells out arm/open and close/disarm order plus an integration test |
| M4 claude-plan still described name similarity, partial hashing, numbered slots | Updated |
| L1 Stale doc comments (`Fingerprint.exact`, `KeyFile`) | Updated |
| L2 Breadcrumb time offset could trap in `CrashIssue` | Clamped |
| L3 No public merge-link reader | `SettingsStore.mergeLinks()` |
| L4 `RouteID` synthesized `Codable` isn't tolerant | Dropped `Codable`; persist the raw string |
| L5 Section 04 "Done when" contradicted the reconciliation | Reworded |
| L6 Scanner printed every game-supplied plugin/module name | Printed only when two distinct games share it; the rest counted as `other` |
| L7 Crash history ignored merges | `CrashHistory.entries(for:links:)` follows merge links; section 13 passes `mergeLinks()` |
