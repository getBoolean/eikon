# Code Review: Section 13 - Library UI

HIGH
1. DrivesView: the fileImporter `isPresented` setter clears `picking`, which also records the purpose; if the binding resets before `onCompletion`, Add/Find folder do nothing.
2. DrivesView alerts read `pendingRelink`/`removing` inside the action while the binding setter clears them; use `.alert(presenting:)`.

MEDIUM
3. GameDetailView: sheets/alerts/onDisappear hang off `detail(game)` inside `if let game`; removing the game tears down the Remove sheet mid-flow and the pop can be ignored on iOS 15.
4. RootView: re-show after Start over flips the binding during the previous alert's dismissal; a single yield may not pass a frame.
5. Import progress shows estimated bytes only, no file count (plan asks files and bytes).
6. FileVerifier: a queued progress Task can overwrite the final `.done(hash)`.

LOW
7. `forget(location:)` cancels the worker even when the location is no longer missing.
8. launch(): `.missing` launch location reported as drive-not-connected.
9. verify(): every non-ready case shows "couldn't be read".
10. Name edits are discarded on focus loss without Return.
11. Crash history footer uses the global clipboard notice.
12. Deviations to record: override as tappable rows (not Picker); no "done" import preview; no settling-row preview; LaunchState checks isBuilt before forced-unavailable.
13. RemoveGameDialog.measure() detached walk ignores cancellation.

Privacy: no logging added; names and hashes only on screen.
