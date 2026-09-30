# Section 12 interview transcript

No items needed the user's input. #6 applies the owner's standing rule (warn before replacing an unreadable file) to the library secret.

## Auto-fixes
- **#1** The `$decisions` sink hops to the main queue, so `refreshAlternative` reads the stored decisions.
- **#2** `AppServices.sceneBecameActive()`: skips the launch activation (covered by `start()`), awaits startup, keeps one refresh at a time.
- **#3** No drive re-evaluation or rescan while a game session is active.
- **#4** Routes recompute only when JIT usability changes; Combine hops use `DispatchQueue.main`.
- **#5a/b** Unreadable files are captured once after wiring (`pendingUnreadable`), cleared by Keep; a start over that leaves files unchanged shows the warning again with a note.
- **#6** An unreadable library secret shows the warn-first screen (file named app-relative, fix and relaunch, or Start over keeping a backup and reopening the data). The generic startup failure no longer promises a restart helps; JIT still follows scene activation there.
- **#7** `LibraryPaths.sessions` and `LibraryPaths.librarySecret` are the single source of those paths.
- **#9** `app.*` and `storage.*` namespaces documented in the strings header; unused `route.reason.runtimeDeclined` removed.

## Let go / manual
- **#5c** Possible iOS 15 alert/NavigationLink race: no iOS 15 device or simulator is available (oldest runtime is iOS 17), so section 13 hardens the alert to show only after the root view appears.
- **#8** Runtime checks open drives on the main actor per game: dormant until runtimes register (later splits).
