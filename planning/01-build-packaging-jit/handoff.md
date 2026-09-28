# Handoff: split 01 — closed

Date: 2026-09-28. Split 01 is done at v0.2.3. `spec.md` has the outcome and how the build differs from the original scope.

## Where things stand

- Released: `Eikon-0.2.3.ipa` (AltStore and TrollStore, `com.getboolean.eikon`) and `com.getboolean.eikon.rootless_0.2.3_iphoneos-arm64.deb` (Dopamine), both on the GitHub release and in the `eikon-source` Sileo repo.
- Device reports for every required case are in `device-reports/`. Its README lists the expected results and what the reports found.
- Pushing a `v*` tag runs the release, which publishes to `eikon-source` without an approval pause.

## How the open problems were resolved

- **TrollStore crash at launch.** `com.apple.private.security.no-sandbox` left the process outside a container, and the sandbox killed it at exec. Removed from both packages.
- **Deb could not write its data container.** Sandboxed under `/var/jb` without a container entitlement, it was denied writes to its own container and the GPU user client. The deb now carries `container-required` for its own bundle id.
- **TrollStore install detected as `unknown`.** The `_TrollStore` marker file was not visible. Detection now reads the `container-required` entitlement that TrollStore adds when it re-signs, and Lite's `jb.pmap_cs.custom_trust`.
- **Sileo installed the old 0.1.0 deb.** The 0.1.0 deb used the id `com.getboolean.eikon`. The deb now declares `Conflicts`/`Replaces` for it. Restarting Sileo cleared the stale state.

## Left for later splits

- A time limit on the wait for JIT after asking TrollStore, for when its "URL Scheme" setting is off.
- A `liveContainer` install method, if wanted. LiveContainer guests currently detect as `unknown`.
- Whether the `com.apple.developer.kernel.*` memory keys have any effect (see `packaging/entitlements/README.md`).
- Developer Mode off on the TrollStore install, and an AltStore free team, are still untested.
