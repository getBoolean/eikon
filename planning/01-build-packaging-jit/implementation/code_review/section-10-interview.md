# Code Review Interview: Section 10 - Packaging, signing and the artifact verifier

**Date:** 2026-09-27

No items needed owner input. `ldid -e` was confirmed to return exactly the plist's keys, so exact matching doesn't false-fail.

## Auto-fixes
- #1: `check_signature` now requires the executable's entitlement set to equal its kind's plist exactly — a missing key, a wrong value or an extra key all fail. The forbidden-key check stays as defence in depth. Confirmed by leaking `get-task-allow` into a deb: verify fails naming the deb and the key.
- #2: `make package` removes `dist/` before repackaging.
- #3: the deb layout check allows only `var` and `var/jb` themselves plus paths under `var/jb/`, and reports every offender.
- #4: `ipa`/`tipa`/`deb` and `package` depend on `archive`.
- #6: `struct.error` is caught per artifact.

## Let go
- #5: the ldid check matches doctor's heuristic exactly; consistency with doctor is the point. A shared helper is a later cleanup.
- #7: arm64-only, guarded by archive.sh; 32-bit Mach-O can't occur.
- #8: presence of the resource seal is what the plan asks for.
