# Code Review: Section 12 - Release workflow and device runbook

Only `release.yml` and `device-reports/README.md` are in scope; Part C (the tag, release, deploy key, Pages, device runbook) is owner-approval-gated and not done here.

Correct and rule-compliant: the trigger is `push` of `v*` tags only; top-level `permissions: contents: read`, widened to `write` only on the release job; `concurrency: publish` with no cancel; all actions SHA-pinned. The build job runs the tag guard then `make all`. The release job's `gh release create` fails on an existing release (no `--clobber`). The publish job gates on `environment: eikon-source`, checks for the deploy key (skipping cleanly when absent), downloads the deb from the release asset URL (not the workflow artifact), pushes to `eikon-source` with the deploy key, and skips an empty commit. The runbook has no titles, states the privacy rule, and its results table matches the plan.

## Medium
1. The publish job indexed whatever curl returned without checking it against the release's SHA256SUMS — a supply-chain gap.

## Low
2. `download-artifact` is a net-new SHA pin (verified against v8.0.1).
3. The ldid-conflict uninstall isn't in the plan's step (benign, matches ci.yml).
