# Code Review: Section 01 - Core Package

Matches the plan. The render-gate ordering is correct, and there are no crash- or security-level bugs. Findings:

1. (High) The read-only rule fails open: a file whose `format` is missing, non-integer or too large for Int is treated as format 0 and overwritten. A JSON `true` bridges to 1.
2. (Medium) RawJSON turns integers above Int64.max into Double, so the raw element is not written back unchanged.
3. (Medium) TolerantList relies on a failed `decode` not advancing the unkeyed container. JSONDecoder does this, but no protocol promises it.
4. (Medium) Fault hook: if `close` races with `record`, the fd can be reused and the record lands in another file. Racing `fault_open` calls leak an fd (it uses store, not exchange).
5. `fault_open` truncates. Section 07 must read the previous fault file first; document that.
6. (Low) `eikon_breadcrumb_write` doesn't save and restore errno.
7. (Low) Add `_Static_assert`s that the atomics are lock-free.
8. (Low) Document that readers ignore a trailing partial fault record.
9. (Low) Stamped needs the document to encode as a keyed object; document it on the protocol.
10. The save-time disk check parses the file twice, and a TOCTOU remains between two savers. Callers must serialize; document it.
11. Durability: F_FULLFSYNC isn't used, and stale temp files are never swept. Matches 01.
12. Decoded elements drop unknown keys by design.

Tests: behavioral and fine. `@testable` isn't needed.
