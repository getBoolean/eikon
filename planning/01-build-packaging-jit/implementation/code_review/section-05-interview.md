# Code Review Interview: Section 05 - Install-method detection

**Date:** 2026-09-27

No items needed owner input.

## Auto-fixes
- #1: the component directly under the preboot hash is redacted whatever its prefix (`dopamine-XXXXXX`, `jb-XXXXXXXX`, …), keeping the text before its first `-`. The redaction test also covers a non-Dopamine rootless layout with a `jb-` suffix.
- #2: the jailbreak rule checks both the unresolved and the resolved bundle path. The resolved `procursus` root is preferred for the `basebin` lookup.
- #3: not reproduced. `detectInstallMethod(.live)` compiled and ran in a temporary simulator test. The parameter is now `some BundleEnvironment` anyway.
- #4: the two components after `var/folders` are redacted.
- #5: a `.jbroot-` component becomes `.jbroot-<id>`. Detecting RootHide is out of scope.
- #7: argument rows cover a TrollStore marker plus a profile (still `.trollStore`) and a jailbreak path plus a profile (still a jailbreak).
- #8, #9: the local is renamed `jbRoot`, and `redactPath` reads from an immutable copy.

## Let go
- #6: rootful installs being `.unknown` is as planned; noted in the section doc for sections 06 and 09.
