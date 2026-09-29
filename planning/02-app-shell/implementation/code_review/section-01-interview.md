# Code Review Interview: Section 01 - Core Package

**Date:** 2026-09-28

## Discussed with user

None. No finding had a real trade-off that needed the owner's input.

## Auto-fixes

- #1: `save` refuses (read-only) when the existing file is a JSON object whose `format` isn't an integer no newer than the app's, including a missing key. A Bool no longer counts as a format. A file that isn't JSON at all stays overwritable: atomic writes mean no build leaves one, so it can only be corruption, and refusing would wedge the store forever. `load` flags such files read-only too.
- #2: RawJSON gains a UInt64 case, tried before Double.
- #4: The header documents that `fault_close`/`fault_open` must run only while no runtime can call `fault_record`. `fault_open` publishes with `atomic_exchange` and closes any fd it replaced.
- #5: The header says to read the previous session's fault file before `fault_open`, because it truncates.
- #6: `eikon_breadcrumb_write` saves and restores errno.
- #7: `_Static_assert`s that the int, int32 and bool atomics are lock-free.
- #8: The header says readers ignore a trailing partial record.
- #9, #10: Doc comments on `PersistedDocument` (the document must encode as a JSON object, and `format` is stamped) and on `PersistedFile` (callers serialize saves to one URL).
- Tests: `@testable import` becomes a plain `import`.

## Let go

- #3: Re-decoding each element through RawJSON would lose the decoder's configuration and double the work. Today's JSONDecoder behavior is pinned by the malformed-element test.
- #11, #12: These match 01 and are by design.
