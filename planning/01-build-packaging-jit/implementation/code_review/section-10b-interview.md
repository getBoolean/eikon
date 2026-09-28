# Code Review Interview: Two-artifact packaging change (2026-09-28)

**Date:** 2026-09-28

Owner decisions already made: drop the tipa, ipa keeps `com.getboolean.eikon` with the TrollStore-friendly entitlements, deb becomes `com.getboolean.eikon.rootless`.

## Auto-fixes
- A: section 11 and section 12 docs now say "two artifacts".
- D: the change note's rationale is corrected (the check skips `__LINKEDIT`, where the CodeDirectory id lives).
- E: "three artifacts"/"tipa" strings updated in verify_artifacts.py, package.sh, AppIdentity.swift, the StatusView preview, DeviceReportTests and the shared fixture (packageKind `ipa`). Tests still pass.
- G: the publish commit message no longer names the old id.

## Flagged, not changed
- B: kept the TrollStore entitlement set on the ipa (no-sandbox has real value — TXM firmware read now, filesystem access for later splits). Made it the **explicit first check** in the AltStore runbook case: if AltStore rejects the private keys, drop them and cut a new version. This is the empirical, device-report-driven approach.
- C: the AltStore/TrollStore ipa collision is inherent to one id for one artifact; documented in the runbook ("uninstall before switching"). Distinct ids per install *method* would mean re-signing to different ids, out of scope.
- F: left as-is; verify catches any drift between package.sh and control.in.
