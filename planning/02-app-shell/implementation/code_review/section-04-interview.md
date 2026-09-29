# Code Review Interview: Section 04 - Collection scanner

**Date:** 2026-09-29

## Discussed with user (during implementation)

- **Share layout.** The real share is organized in group folders (games up to 4 levels deep); a flat scan finds far fewer games than the requirements table. User: "import will copy the game files to the correct file structure. flat as planned." The scanner and the app stay flat.

## Auto-fixes

- #1 Keep the detection when fingerprinting or declared-id reading fails; count those as `identity-errors`.
- #2 One per-folder line for every folder (`none` / `error` for non-games), in visit order; sorted by fingerprint only with --hash.
- #3 Only a missing root is skipped; an unreadable root (or a file) is a separate outcome, reported on stderr with exit 1.
- #4 The pytest compares the table's Unity row with `unity.unityplayer` (the table counts Unity by UnityPlayer.dll). Reconciliation is recorded in the section doc.
- #5 Detect into a per-folder tally, merged only on success.
- #6 Print every exclusion rule, zero included.
