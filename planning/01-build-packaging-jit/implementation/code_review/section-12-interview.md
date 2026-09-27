# Code Review Interview: Section 12 - Release workflow and device runbook

**Date:** 2026-09-27

No items needed owner input for the two files. Part C's outward-facing steps are presented to the owner separately.

## Auto-fixes
- #1: the publish job now also downloads the release's `SHA256SUMS` and runs `sha256sum -c` on the deb before `build_index.py`, so a corrupt or partial download can't be published.

## Let go / verified
- #2: the `download-artifact` pin `3e5f45b…` was confirmed against the real v8.0.1 tag.
- #3: the ldid-conflict uninstall matches `ci.yml` and avoids a Homebrew formula clash.
