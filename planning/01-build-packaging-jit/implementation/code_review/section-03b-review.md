# Code Review: Section 03 (rework) - Third-party libraries from fork releases

The design matches the plan. There is no way to unpack an asset whose hash differs from its pin, and paths stay inside `build/deps`. Findings:

## High
1. The swap (`rmtree(final)`, then rename) can be interrupted with the in-tree stamp surviving, so `verify` accepts a half-deleted dependency.
2. The stamp write follows a `.eikon-dep` symlink from the archive.

## Medium
3. `.tar.zst` and other unsupported `.tar.*` assets are silently copied as a single file.
4. pin's "nothing else changed" check ignores `upstream`; the rewrite normalises line endings.
5. `pin` re-pins a release whose asset was replaced under the same tag, without warning.
6. Tar, zip, HTTP and rmtree errors escape as tracebacks; `IncompleteRead` leaves a `.part` file.
7. Orphaned `build/deps/<name>` directories and leftover staging directories are never flagged.

## Low
8. `verify` checks only the stamp, not the files.
9. Zip extraction drops the executable bit.
10. `pin` downloads into a temporary directory, so `fetch` downloads again.
11. A truncated download reads like tampering.
12. No authentication for private forks.
