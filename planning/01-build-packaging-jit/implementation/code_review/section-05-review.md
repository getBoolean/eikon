# Code Review: Section 05 - Install-method detection

The code matches the plan: the rule order, complete evidence, component-based redaction, realpath(3), and four behavioural tests. No crash or data-loss risk.

1. HIGH: other rootless jailbreaks leak their per-install suffix (for example palera1n's `jb-XXXXXXXX` under the preboot hash); only `dopamine-` is redacted.
2. MEDIUM: the jailbreak rule checks only the resolved path, so a `/var/jb` that resolves outside `.../procursus` is missed.
3. MEDIUM: `detectInstallMethod(.live)` might not compile with an existential parameter.
4. LOW: the Mac "Designed for iPad" bundle path under `/private/var/folders/<xx>/<random>` isn't redacted.
5. LOW: RootHide's `.jbroot-<hex>` isn't redacted.
6. LOW: rootful installs classify as `.unknown` (worth noting for sections 06 and 09).
7. LOW: tests don't cover the rule-order conflicts.
8. NIT: `jailbreakRoot` shadows the function it calls.
9. NIT: `redactPath` reads `previous` from the array it is rewriting.
