# Code Review Interview: Section 11 - Publishing to the eikon-source Sileo repo

**Date:** 2026-09-27

No items needed owner input.

## Auto-fixes
- #1: the swap tracks a `swapped` flag and, on any failure after moving the old docs aside, restores them (`backup.rename(out_docs)`) before cleaning up. A new test proves a failed rebuild leaves the previous docs and their version intact, with no leftover siblings.
- #2: the Packages stanza ends with a blank line.
- #3: `_description_text` strips continuation indent and turns ` .` into blank lines; only the templates use it, so the Packages file keeps raw Debian formatting.
- #4: `file_digests` streams the file in 1 MiB chunks.
- #5: a comment notes Sileo verifies SHA256; the MD5Sum section is for apt-style tooling.
- #6: renamed `IndexBuildError`.
