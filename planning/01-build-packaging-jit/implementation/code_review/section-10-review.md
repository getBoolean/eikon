# Code Review: Section 10 - Packaging, signing and the artifact verifier

`make all` passes end to end; the verifier confirms one binary across the ipa, tipa and deb and catches a forbidden key, a junk file, and (after the fix) a leaked per-kind entitlement. The Mach-O parsing (LC_UUID, segment hashes excluding __LINKEDIT, the CodeDirectory resource-seal slot, the fat/thin arm64 slice) is correct.

## High
1. The verifier only enforced a superset of entitlements, so a deb leaking `get-task-allow`, or an ipa leaking a private key, would pass. That defeats the "differ only in entitlements" contract.

## Medium
2. `dist/` was never cleared before packaging, against the plan; stale artifacts from an old version could linger.
3. The deb layout check only looked at the top path component and stopped at the first violation.
4. `ipa`/`tipa`/`deb` and `package` didn't depend on `archive`, so `make -jN` could reorder them.
5. package.sh reimplements the ldid-Procursus check instead of sharing doctor's.

## Low
6. `struct.error` from a malformed Mach-O wasn't caught in the main loop.
7. `is_macho` doesn't recognise 32-bit Mach-O (fine given arm64-only).
8. The resource seal is checked for presence, not against the actual CodeResources (as the plan allows).
