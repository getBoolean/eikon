# Code Review Interview: Section 07 - Sessions and crash

**Date:** 2026-09-29

No questions for the user; all findings auto-fixed or documented.

## Auto-fixes

- #1 Trimming test forces overflow with long device strings; asserts dropped > 0, fits, newest kept, oldest gone.
- #2 C writers count in-flight calls; close swaps the fd to -1 and waits for in-flight to drain before closing.
- #3 A history file that exists but fails to load is treated as read-only (never overwritten).
- #4 Public `Breadcrumb.init(seq:time:event:)`; tests build crumbs from events.
- #5 Round-trip test checks the full key set and each value.
- #6 Memory-warning window requires a non-negative gap.
- #7 `setPhase` throws when the sentinel is missing; `disarm` fsyncs the directory. Documented for sections 10/11: consume before arm, add to history right after consume.
- #8 Slot and fault offsets exported as C macros and used by the Swift readers.
- #9 Reader rejects a slot whose seq doesn't belong at its index; test for a truncated file.
