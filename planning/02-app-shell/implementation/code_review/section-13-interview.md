# Code Review Interview: Section 13 - Library UI

**Date:** 2026-09-30

No items needed the owner's input.

## Auto-fixes
- #1 DrivesView: separate `showPicker` for presentation from the `picking` purpose; clear the purpose in the completion handler.
- #2 DrivesView: both alerts use `.alert(_:isPresented:presenting:)` so the action receives its value.
- #3 GameDetailView: modifiers move outside the `if let game`; the Remove sheet pops the detail from the sheet's `onDismiss` once the game is gone.
- #4 RootView: re-show after Start over waits for the dismissal (short sleep) instead of a single yield.
- #6 FileVerifier: progress updates ignored once a run is finished (per-run token).
- #7 forget(location:): cancel the worker only when the location is actually removed.
- #8 launch(): `.missing` gets its own message.
- #9 Verify files is offered only when the launch location is reachable and has a key file.
- #10 Name commits on focus loss as well as on Return (still never per keystroke).

## Let go
- #5 File counts: ImportCoordinator reports a fraction only; bytes of total shown. Recorded as a deviation.
- #11 Global clipboard notice: it is about the last report, wherever filed; acceptable.
- #12 Recorded in the section doc. The LaunchState order is right: an unbuilt route has no runtime, so "Launch anyway" couldn't start it.
- #13 Size walk only runs while the dialog is open for local folders; acceptable.
