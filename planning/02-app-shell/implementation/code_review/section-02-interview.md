# Code Review Interview: Section 02 - Detection

**Date:** 2026-09-29

## Discussed with user

None. Every finding was technical, with a clear fix and no product trade-off.

## Auto-fixes

- #1: `FolderReader` caches `ParsedBinary`, `.rsrc` data and version strings per path, so each exe is parsed once per pass and later callers (section 03) get cached strings. Reads charge the bytes actually read.
- #2: Ren'Py `__init__.py` with several `version_tuple`s picks by the lib layout: major ≥ 8 when `lib/` has py3-*/python3.*, else the lowest major. `text(prefix:)` reads the first 64 KiB of larger files.
- #3: `normalize` = NFC(fold(NFC(x))). Unity pairing compares keys directly (`file(key:)`).
- #4: The Ren'Py version files are looked up through the `game/` and `renpy/` listings.
- #5: The fallback scan reads `.rdata`, then `.data`, then `.rsrc`, within the budget that remains after the cached version-resource read.
- #6: The declared unpacked size is capped at packed × 1032 (zlib's maximum ratio) before any allocation.
- #7: `executables` encodes in `GamePlatform.allCases` order.
- #8: Linux extensions add x86_32, arm32, appimage and run.
- #9: `read` opens with O_NONBLOCK and refuses anything but a regular file (fstat).
- #11: Plugin and extension names are de-duplicated by normalized key and sorted by it.
- #12: `ExclusionTally` documents that every evaluated folder counts, including a root that turns out not to be the game.

## Let go

- #10: `files(withExtension:)` stays, because it filters to regular files and the name says so. The section doc records the name.
- #13: These are planned behavior. `GamePlatform`/`BinaryFormat` must throw so that unknown entries are dropped.
- The weak listing-order test stays. It still pins sorted iteration on file systems that don't return entries sorted.
