# Code Review: Section 04 - Collection scanner

Matches the plan overall; no title leaks. Findings:

1. A hashing or identity failure after a successful detect() drops the detection and counts only as an error, so --hash runs can report different engine counts.
2. Per-folder output skips no-game and error folders, and sorts even without fingerprints (visit order not guaranteed).
3. An existing but unreadable root (or a file) prints "skipped: not mounted" and exits 0.
4. Reconciliation against the mount has no evidence; the pytest compares the table's Unity row (counted by UnityPlayer.dll) against engine.unity instead of unity.unityplayer.
5. Exclusion hits from a folder whose detect() throws stay in the tally.
6. exclusion.* lists only rules with hits; the plan asks for every rule.
