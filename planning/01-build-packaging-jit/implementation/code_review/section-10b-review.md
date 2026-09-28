# Code Review: Two-artifact packaging change (2026-09-28)

Dropping the `.tipa` and giving the deb a distinct id is correct and release-safe. The tipa is gone from package.sh, the Makefile, verify_artifacts.py, release.yml and the entitlements; the deb's new id threads consistently through the stamp, the `-I` signing identifier, the doc dir, the filename and control.in (and verify checks Package == CFBundleIdentifier). Install detection is id-independent (it keys off the `/var/jb` path and Dopamine markers), so the deb id change doesn't affect Dopamine detection or JIT policy.

## Medium
A. Runbook (section 12) and section 11 still said "three artifacts" — operator-facing drift.
B. The shipped ipa now embeds two private entitlements (`no-sandbox`, `memorystatus`) the working 0.1.0 ipa lacked. If AltStore validates rather than silently strips, the AltStore install could fail. Unverified until the next AltStore install.

## Low
C. AltStore-ipa and TrollStore-ipa still share `com.getboolean.eikon` and shadow each other (documented, not solved).
D. The change note's same-binary rationale was wrong (the id is in the CodeDirectory in `__LINKEDIT`; the check holds because it skips `__LINKEDIT`).
E. Stale "three artifacts"/"tipa" strings in shipped code (docstrings, comments, a preview sample and the fixture packageKind).
F. The rootless id is duplicated in package.sh and control.in (guarded by verify).
G. The publish commit message still named the old id.
