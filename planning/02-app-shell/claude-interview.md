# Interview: split 02 (app shell)

Date: 2026-09-28. Informed by `spec.md` and `claude-research.md`.

## Q1. How should imported game folders be stored?
Options offered: copy always; copy + reference local; Documents drop-in only; both picker and drop-in.

**A:** "I'd like for games to be able to be stored on an external drive."

## Q2. Which file's hash is a game's identity, and what happens when that file changes?
Options offered: main archive first; main exe always; stable id + build id.

**A:** Stable id + build id.

## Q3. Full SHA-256 of the key file, or a sampled fingerprint?
**A:** Full SHA-256.

## Q4. How much should the app do to record a game crash for the next launch?
**A:** Session sentinel + breadcrumbs. No signal handlers (avoids conflicts with FEX/Wine fault handling); runtimes may add an "unhandled fault" hook later.

## Q5. External storage: referenced vs copied?
**A:** Both; the user chooses at import ("Copy into Eikon" or "Keep on drive"). Referenced games get a reachability check before launch, show "drive not connected" in the library, and re-link when the bookmark goes stale.

## Q6. Which kinds of external storage must work in place?
**A:** USB-C SSD / SD card only (locally attached; APFS, exFAT, FAT). Not SMB, not iCloud/file providers.

## Q7. What should the stable game id be derived from?
Options offered: content-archive hash; first-seen build id; random UUID.

**A:** "None of these are good. Can we just use the folder name?"

## Q8. How should the folder name be used, given no titles in logs, exports or sync paths?
**A:** Folder-name hash + build match. Stable id = SHA-256 of the normalized folder name (the name itself never leaves the device or reaches logs). Build id = SHA-256 of the main exe/archive. If a new import's build id matches a known game under a different folder name, offer to attach it to that game.

## Q9. Where should hashing run?
**A:** In the background with progress. The game appears immediately as "identifying…", detection is instant, the hash runs in the background, and settings/launch unlock when done. Re-hash only if size/mtime changed.

## Q10. Default display name?
**A:** The folder name, editable by the user (display name is a synced setting).

## Q11. Collection scanner: same Swift code or separate Python?
**A:** Same Swift code. Detection and hashing go in a platform-neutral package target (no UIKit) that builds on macOS; the scanner is a small Swift executable run via a make target. Detection unit tests can run with `swift test` on the Mac.

## Q12. With no runtimes built yet, what does the route picker show?
**A:** The planned route, marked "not in this build yet". Routes register as available when their split lands.

## Q13. Unmeasured device gates?
**A:** Unmeasured = allowed, with a warning. A failing gate removes the route.

## Q14. Library layout?
**A:** iPad sidebar split view (sidebar list + detail on iPad, stack on iPhone).

## Q15. Route override onto a route that "cannot run"?
**A:** Allow anything, warn. The launch shows why it may fail.

## Q16. After a crash / likely memory kill is detected on next launch?
**A:** All of: banner with details; export (see Q20); suggest another route; per-game crash history.

## Q17. Strings?
**A:** Move to `en.lproj/Localizable.strings` now (plus `.stringsdict` for plurals) so 09 only adds languages.

## Q18. Removing a game from the library?
**A:** Ask about both the game files and the settings/saves, including those on the sync server.

## Q19. Documents/Games drop-in folder auto-scanned?
**A:** Yes. Folders dragged into Eikon's Documents/Games via Files.app or Finder appear on next foreground. Needs `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`.

## Q20. Crash records: extend DeviceReport or separate file?
**A:** "Opens a prefilled GitHub issue."

## Q21. Gate results store?
**A:** A persisted gate store in EikonKit keyed by gate name (GateResult + build + OS version), invalidated when the OS version or app build changes; `DeviceReport.make` fills `gates` from it.

## Q22. Capability screen vs 01's status screen?
**A:** Extend the status screen into one "This device" screen: existing JIT/device/report rows plus a route table and gate results.

## Q23. What goes in the crash issue body?
**A:** Crash record + device summary: kind, engine, arch, route, stable-id and build hashes, app build, device model, iOS, install method, JIT state, last ~20 breadcrumbs. Never titles or display names. If the full device report doesn't fit the URL, it is copied to the clipboard.

## Q24. Issue template?
**A:** Yes: `.github/ISSUE_TEMPLATE/crash.yml` with a `crash` label; the app's URL targets it.

## Round after plan review (2026-09-28)

## Q25. Folder-name ids collide (two different games both in folders named e.g. "Game"). How to handle?
**A:** Require a flat folder structure. The user sets up **game drives**: folders where games are stored. A game drive can be a folder on a USB drive or on local storage. At import the user chooses the game, then chooses the game drive (local storage or USB).

## Q26. Confirming the game-drive model
My reading, confirmed: Eikon's own folder is always a game drive, and the user can add others (a folder on a USB drive, or a local folder). Each game is an immediate subfolder of a game drive, so names are unique per drive. Every game drive is auto-scanned. Import means picking a game folder, then picking a destination game drive, then copying it in. There is no separate "reference an arbitrary folder" mode.

**A:** Yes, exactly. The **default game drive is "On My iPad/Eikon"** (the app's Documents folder as Files shows it). The UI must make it clear that **game files are copied to the game drive**.

## Q27. Same folder name on two different game drives?
**A:** Ask on build mismatch. If the build ids match, it's the same game. If they differ, ask whether it's the same game (updated) or a different one.

## Q28. A game-drive subfolder with no game at its root?
**A:** Look one level down (accept a single wrapper level containing exactly one game).

## Q29. Crash issue ids (folder-name hashes are dictionary-reversible; build ids are matchable)?
**A:** Keyed short ids. HMAC(per-install secret, game id), truncated to 8 characters. No build id in the issue.

## Q30. Gate staleness after app update?
**A:** Keep failures until re-measured. Passed results expire on an app or OS build change. Failed results persist, marked stale, until they are measured again.

## Q31. Revisiting identity (after the TDD plan was drafted)
**Owner:** "I'm not convinced on game ids or game identity." The concerns: folder names are fragile, there are too many prompts, and the design is too complex. The owner asked how other game launchers handle it (research: `claude-research.md` Part D).

**A:** UUID + fingerprint.
- Each game gets a random id.
- Eikon finds a game again by a fingerprint:
  - the engine's own declared id (Ren'Py `save_directory`, Unity company/product, GameMaker name, exe version info)
  - the game root's file listing and sizes
  - a partial hash of the key file
- Renames, moves, patches and a second device match silently.
- The user is asked only when a folder matches a game by engine id but differs in files while that game is still present elsewhere, and the question is non-blocking.
- Fingerprints are stored and synced as keyed hashes, never titles.

This replaces folder-name ids, build ids, aliases and attach prompts. Game drives, the flat layout and the one-wrapper rule stay.
