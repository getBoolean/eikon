# Code Review: Section 02 - Detection

The implementation follows the plan. Bounds checks are careful, and no hostile file leads to a crash or an infinite loop. Findings:

1. (High, latent) Budgets charge the requested length, and one exe is re-parsed up to four times per pass. The Kirikiri fallback scan spends the whole remaining versionResource budget. As a result, section 03's `PEVersionResource` call in the same pass would get `[:]`.
2. (Medium) Ren'Py 7.5/8.0 `__init__.py` has two `version_tuple` lines (PY2/PY3). The first match wins, so an 8.0 game reports 7.5. Separately, `text()` returns nil for files over 64 KiB instead of reading a prefix.
3. (Medium) `normalize` isn't idempotent: case folding can produce non-NFC text. Unity stem pairing re-normalizes keys.
4. (Medium) The Ren'Py version files are opened by literal-case paths, not through a listing.
5. (Medium) The Kirikiri fallback scans `.rsrc`, which was already parsed, instead of the exe's string data. It has no test.
6. (Medium) A 10-byte hostile XP3 index can force a 64 MiB zero-filled allocation through `uncompress`.
7. (Low-Medium) `executables` encodes in Dictionary order, which changes between processes.
8. (Low) The Linux extension allow-list misses x86_32, arm32, AppImage and run.
9. (Low) `read` has no O_NONBLOCK and no fstat regular-file check; a FIFO passed to the public `strings(ofFile:)` would block.
10. (Low) The code names `files(withExtension:)` where the plan says `entries(withExtension:)`.
11. (Low) Plugin and extension names are de-duplicated and sorted by raw name, not by normalized key.
12. (Low) Tally semantics for roots that aren't the game are not written down.
13. Notes: a loose top-level exe blocks the wrapper rule (as planned). An unknown RenPyVersionKind drops the whole version. Some enums have no custom decoder; `try?` covers them.

The deliberate choices hold up: the class reader (given a cache), the extension gate, rules applied after parsing and in order, and flavor resolved after selection. The format walks (PE, rsrc, XP3 with continuation, GameMaker, Unity) were checked and are correct. The tests are behavioral. The listing-order test is weak on APFS.
