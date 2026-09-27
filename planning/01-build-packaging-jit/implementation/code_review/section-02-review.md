# Code Review: Section 02 - Xcode project, app shell and minimal CI

The implementation matches the plan. Every planned file is present, the xcconfig order is right, the Info.plist has the required keys and no entitlements, there are no build-phase scripts, and nothing is below the iOS 15 API floor. The deliberate deviations (`settingPresets: project` with target configFiles, `test: targets:`, `brew update`) are sound.

## High / Medium
1. test_swift.sh: `launchctl list | grep -q` under `pipefail` can fail at random (SIGPIPE, exit 141), so a running app is reported as exited.
2. The launch check matches only the job label, not a live PID, and uses an unanchored regex.
3. An `EIKON_SIM_DESTINATION` without `id=` skips the launch check and exits 0. A non-simulator id gives an unclear error.

## Low
4. `simctl boot ... 2>/dev/null || true` hides real boot errors.
5. The simulator tie-break by name is arbitrary; add a comment.
6. Confirm `uv run --no-project` uses Python 3.12.
7. CI Xcode selection can't tell a beta from a release with the same version.
8. CI: no `timeout-minutes`; `push` plus `pull_request` runs twice.
9. bootstrap.sh does not upgrade tools that are already installed.
10. Target presets are off: CODE_SIGN_IDENTITY and the Mac-support settings aren't restated. Section 10's archive should confirm nothing is missing.
11. `project: version` rewrites Version.xcconfig on every run, so Info.plist is reprocessed each time.
