# Code Review Interview: Section 02 - Xcode project, app shell and minimal CI

**Date:** 2026-09-27

## Owner decisions
- **#9 bootstrap upgrades.** Owner: "Also upgrade". Bootstrap runs `brew update`, installs the missing formulas, and runs `brew upgrade` on the Eikon formulas Homebrew already manages. Tools installed some other way are left alone.
- **#8 CI triggers.** Owner: "Every push, which should cover PRs by itself. Still needs the concurrency group by branch and the time limit". `on: push` only (`pull_request` is dropped), `concurrency` grouped by ref with `cancel-in-progress`, and `timeout-minutes: 45` on the build job.

## Auto-fixes
- #1/#2: capture `launchctl list` first, then require a line whose label starts with `UIKitApplication:<bundle id>[` and whose PID is numeric (fixed-string match, via awk).
- #3: a destination without `id=<udid>` fails with a clear message. The UDID must be a simulator listed by `simctl list devices`.
- #4: tolerate only the "current state: Booted" boot error; print any other error and fail.
- #5: comment that the tie-break by name is arbitrary.

## Let go
- #6: checked. `uv run --no-project` from the repo root uses 3.12.14.
- #7: the log already prints the chosen `xcodebuild -version`; revisit if a runner ever lands on a beta.
- #10: section 10 checks this when archiving.
- #11: cosmetic incremental-build cost; out of scope.
